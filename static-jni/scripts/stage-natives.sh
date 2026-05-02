#!/usr/bin/env bash
# stage-natives.sh — build Netty native + static-archive JARs for one Maven
# profile and stage them in Maven repo layout under a local directory.
#
# Lives outside the netty source tree so it doesn't pollute upstream-bound
# diffs. Intended workflow:
#
#   1. (once per branch update) run with --prep-deps to populate ~/.m2 with
#      the Java-only sibling modules that native modules depend on.
#   2. for each platform host (mac / linux container / windows / bsd VM),
#      run with the appropriate profile and a shared $STAGE directory.
#      rsync between hosts to merge per-host outputs into a single tree.
#
# The stage dir ends up in standard Maven repo layout (groupId/artifactId/
# version/...), ready to upload to a private repo or rsync as a unit.

set -euo pipefail

# Default NETTY_DIR resolution (in priority order):
#   1. Explicit NETTY_DIR env var.
#   2. Grandparent of script dir, IF it has mvnw (the canonical layout —
#      script lives at netty/static-jni/scripts/stage-natives.sh).
#   3. Parent of script dir, IF that parent has mvnw (legacy: script lived at
#      netty/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_parent="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -n "${NETTY_DIR:-}" ]]; then
  : # already set explicitly
elif [[ -x "$script_parent/../mvnw" ]]; then
  NETTY_DIR="$(cd "$script_parent/.." && pwd)"
elif [[ -x "$script_parent/mvnw" ]]; then
  NETTY_DIR="$script_parent"
else
  NETTY_DIR="$script_parent"  # fall through; the existence check below will fail with a clear message
fi

usage() {
  cat <<EOF
Usage: $0 <stage-dir> <profile> [--prep-deps]

  <stage-dir>    Absolute path to a writable directory. Created if missing.
  <profile>      Maven profile to activate. One of:
                   mac | mac-m1-cross-compile | mac-intel-cross-compile
                   openbsd | freebsd
                   linux | linux-aarch64 | linux-riscv64
                   windows
  --prep-deps    Before staging, install all Java-only sibling modules to
                 ~/.m2 so native modules can resolve their classes-only deps.
                 Run once per branch update; idempotent thereafter.

Environment:
  NETTY_DIR      Path to the netty checkout. Default: $NETTY_DIR
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 1
fi

STAGE="$1"
PROFILE="$2"
shift 2

PREP=0
for arg in "$@"; do
  case "$arg" in
    --prep-deps) PREP=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

# Map profile → modules whose static-jar execution is opted-in for that profile,
# plus the actual mvn -P<MVN_PROFILE> to activate. Most platforms map 1:1, but
# linux-aarch64 maps to the `linux` mvn profile when running on a native arm64
# host (Apple Silicon Docker → linux/arm64); the `linux` profile auto-detects
# arch via os.detected.arch and produces `linux-aarch_64` classified artifacts.
# The upstream `linux-aarch64` mvn profile is amd64→aarch64 cross-compile and
# requires user-provided aprArmHome / opensslArmHome — not used here.
# Resolve host arch for profiles that auto-detect (mac, linux). Maps the
# `uname -m` value to the canonical names used by cflags/<arch>.txt.
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64)        echo amd64 ;;
    aarch64|arm64)       echo arm64 ;;
    riscv64)             echo riscv64 ;;
    *)                   uname -m ;;
  esac
}

MVN_PROFILE="$PROFILE"
case "$PROFILE" in
  mac)
    MODULES=(transport-native-kqueue codec-native-quic resolver-dns-native-macos)
    CFLAGS_OS=darwin; CFLAGS_ARCH=$(host_arch)
    ;;
  mac-m1-cross-compile)
    MODULES=(transport-native-kqueue codec-native-quic resolver-dns-native-macos)
    CFLAGS_OS=darwin; CFLAGS_ARCH=arm64
    ;;
  mac-intel-cross-compile)
    MODULES=(transport-native-kqueue codec-native-quic resolver-dns-native-macos)
    CFLAGS_OS=darwin; CFLAGS_ARCH=amd64
    ;;
  openbsd|freebsd)
    MODULES=(transport-native-kqueue)
    CFLAGS_OS="$PROFILE"; CFLAGS_ARCH=$(host_arch)
    ;;
  linux)
    MODULES=(transport-native-epoll transport-native-io_uring codec-native-quic)
    CFLAGS_OS=linux; CFLAGS_ARCH=$(host_arch)
    ;;
  linux-aarch64)
    MODULES=(transport-native-epoll transport-native-io_uring codec-native-quic)
    MVN_PROFILE=linux
    CFLAGS_OS=linux; CFLAGS_ARCH=arm64
    ;;
  linux-riscv64)
    MODULES=(transport-native-epoll transport-native-io_uring)  # quic has no riscv64
    MVN_PROFILE=linux
    CFLAGS_OS=linux; CFLAGS_ARCH=riscv64
    ;;
  windows)
    # Static JAR for windows-x86_64 is deferred (cmake/msbuild path); this
    # only stages the existing shared-lib classifier JAR for completeness.
    MODULES=(codec-native-quic)
    CFLAGS_OS=windows; CFLAGS_ARCH=amd64
    ;;
  *)
    echo "Unknown profile: $PROFILE" >&2
    usage >&2
    exit 1
    ;;
esac

# Canonicalize STAGE so altDeploymentRepository receives an absolute file URL.
mkdir -p "$STAGE"
STAGE="$(cd "$STAGE" && pwd)"

if [[ ! -d "$NETTY_DIR" ]]; then
  echo "NETTY_DIR not found: $NETTY_DIR" >&2
  exit 1
fi

# Docker-on-Mac bind mounts make `File.canExecute()` falsely return true,
# which short-circuits hawtjni's `CLI.setExecutable()` so the extracted
# autogen.sh stays 0644 and fails with EACCES. rsync to a non-bind-mount
# work dir (the container's overlay fs) before building. Output `$STAGE`
# can stay on the bind mount — only the build tree needs +x propagation.
if [[ -n "${NETTY_REWORK:-}" ]] || \
   ([[ -f /.dockerenv ]] && stat -c %m "$NETTY_DIR" 2>/dev/null | grep -q -v "^/$"); then
  if ! command -v rsync >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache --quiet rsync >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q rsync >/dev/null 2>&1 || true
    fi
  fi
  WORKDIR="${NETTY_REWORK:-/tmp/netty-work}"
  echo "==> Copying source from $NETTY_DIR → $WORKDIR (bind-mount workaround)"
  mkdir -p "$WORKDIR"
  ORIG_NETTY_DIR="$NETTY_DIR"
  rsync -a --delete --exclude='target/' --exclude='.git/' \
    "$NETTY_DIR/" "$WORKDIR/"
  # Symlink .git back to the bind-mounted source so the version-properties
  # antrun (write-version-properties in netty-parent) can resolve commit hash
  # / status — copying .git would add hundreds of MB to every build. Add the
  # work dir as a safe.directory so git inside the container (running as root)
  # accepts a repo whose objects are owned by the host uid.
  if [[ -d "$ORIG_NETTY_DIR/.git" ]]; then
    ln -sfn "$ORIG_NETTY_DIR/.git" "$WORKDIR/.git"
    git config --global --add safe.directory '*' >/dev/null 2>&1 || true
  fi
  NETTY_DIR="$WORKDIR"
fi

cd "$NETTY_DIR"

if [[ ! -x ./mvnw ]]; then
  echo "Maven wrapper not found at $NETTY_DIR/mvnw" >&2
  exit 1
fi

# Toolchain selection:
#   - On Mac, use Apple's clang (already on PATH; supports -flto=thin).
#   - On Alpine Linux (preferred for Linux builds): clang 22 + musl libc. Avoids
#     glibc-specific symbol references like `__strdup` / `__isnan` that show up
#     in the static .a when built against glibc and break downstream musl links.
#     Alpine 3.21+ ships `clang22` in community; we install + use it as the C
#     and C++ compiler. Apple Silicon Docker runs linux/arm64 natively here.
#   - AlmaLinux 9 is kept as a fallback path (uses base gcc 11 — glibc, so the
#     resulting .a will reference `__strdup`/`__isnan` and won't link cleanly
#     against musl. Use Alpine instead for production static-JNI artifacts).
if command -v apk >/dev/null 2>&1; then
  # Alpine Linux (musl). Install clang 22 + LLVM tools, build deps, JDK, Rust.
  if ! command -v clang-22 >/dev/null 2>&1; then
    apk add --no-cache --quiet \
      build-base clang22 clang22-extra-tools llvm22 lld22 compiler-rt \
      cmake samurai patch perl perl-utils python3 \
      autoconf automake libtool make git rsync which file linux-headers musl-dev \
      libstdc++-dev apr-dev openssl-dev openjdk17-jdk rust cargo >/dev/null 2>&1 || true
    # Alpine ships ninja under `samurai` (the package's binary is `samu`); also
    # try `ninja-build` alias for tools that hardcode that name.
    [[ -x /usr/bin/samu && ! -e /usr/bin/ninja ]] && ln -sf /usr/bin/samu /usr/bin/ninja
    [[ -x /usr/bin/ninja && ! -e /usr/bin/ninja-build ]] && ln -sf /usr/bin/ninja /usr/bin/ninja-build
  fi
  # Symlink unversioned clang/clang++/llvm-ar etc. so configure scripts and
  # cmake's auto-detect find them as `clang` rather than `clang-22`.
  # clang/clang++ are named `clang-22` / `clang++-22` on Alpine. The LLVM
  # tools use the prefix-style `llvm22-<tool>` (e.g. /usr/bin/llvm22-ar).
  for tool in clang clang++; do
    [[ -x /usr/bin/${tool}-22 && ! -e /usr/local/bin/$tool ]] && \
      ln -sf /usr/bin/${tool}-22 /usr/local/bin/$tool
  done
  for tool in ar ranlib nm objcopy strip; do
    [[ -x /usr/bin/llvm22-${tool} && ! -e /usr/local/bin/llvm-${tool} ]] && \
      ln -sf /usr/bin/llvm22-${tool} /usr/local/bin/llvm-${tool}
  done
  [[ -x /usr/bin/ld.lld-22 && ! -e /usr/local/bin/ld.lld ]] && \
    ln -sf /usr/bin/ld.lld-22 /usr/local/bin/ld.lld
  [[ -z "${JAVA_HOME:-}" && -d /usr/lib/jvm/java-17-openjdk ]] && export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
elif command -v yum >/dev/null 2>&1; then
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release ]] || \
     grep -q '^VERSION_ID="9' /etc/os-release 2>/dev/null; then
    # AlmaLinux/Rocky/RHEL 9 (glibc fallback path).
    command -v rsync >/dev/null 2>&1 || NEED_DEPS=1
    command -v cmake >/dev/null 2>&1 || NEED_DEPS=1
    command -v ninja-build >/dev/null 2>&1 || NEED_DEPS=1
    command -v patch >/dev/null 2>&1 || NEED_DEPS=1
    command -v perl >/dev/null 2>&1 || NEED_DEPS=1
    command -v gcc >/dev/null 2>&1 || NEED_DEPS=1
    command -v g++ >/dev/null 2>&1 || NEED_DEPS=1
    command -v which >/dev/null 2>&1 || NEED_DEPS=1
    command -v autoreconf >/dev/null 2>&1 || NEED_DEPS=1
    command -v libtoolize >/dev/null 2>&1 || NEED_DEPS=1
    command -v javac >/dev/null 2>&1 || NEED_DEPS=1
    if [[ "${NEED_DEPS:-0}" == 1 ]]; then
      yum install -y -q epel-release >/dev/null 2>&1 || true
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
      yum install -y -q rsync gcc gcc-c++ libstdc++-static cmake ninja-build patch \
        perl perl-IPC-Cmd perl-Time-Piece autoconf automake libtool make git which \
        java-17-openjdk-devel >/dev/null 2>&1 || true
    fi
    if [[ -z "${JAVA_HOME:-}" ]]; then
      if [[ -d /usr/lib/jvm/java-17-openjdk ]]; then
        export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
      else
        JAVA_HOME=$(ls -d /usr/lib/jvm/java-17-openjdk-* 2>/dev/null | head -1)
        [[ -n "$JAVA_HOME" ]] && export JAVA_HOME
      fi
    fi
    if ! command -v cargo >/dev/null 2>&1; then
      yum install -y -q rust cargo >/dev/null 2>&1 || true
    fi
  else
    # CentOS 7 path (netty:centos-7-1.17 image, retained as historical fallback).
    if [[ ! -f /opt/rh/devtoolset-11/enable ]]; then
      yum install -y -q centos-release-scl >/dev/null 2>&1 || true
      yum install -y -q devtoolset-11 >/dev/null 2>&1 || true
    fi
    command -v cmake       >/dev/null 2>&1 || NEED_DEPS=1
    command -v ninja-build >/dev/null 2>&1 || NEED_DEPS=1
    command -v patch       >/dev/null 2>&1 || NEED_DEPS=1
    command -v perl        >/dev/null 2>&1 || NEED_DEPS=1
    if [[ "${NEED_DEPS:-0}" == 1 ]]; then
      yum install -y -q epel-release >/dev/null 2>&1 || true
      yum install -y -q cmake3 patch ninja-build perl perl-IPC-Cmd perl-Time-Piece >/dev/null 2>&1 || true
      if [[ -x /usr/bin/cmake3 && ! -e /usr/local/bin/cmake ]]; then
        ln -sf /usr/bin/cmake3 /usr/local/bin/cmake
      fi
    fi
    if [[ -f /opt/rh/devtoolset-11/enable ]]; then
      # shellcheck disable=SC1091
      source /opt/rh/devtoolset-11/enable
    fi
  fi
fi
# cargo is pre-installed in netty:centos-7-1.17 under /root/.cargo/bin but not
# on the default PATH; quic's quiche build needs it.
if [[ -d /root/.cargo/bin ]] && ! command -v cargo >/dev/null 2>&1; then
  export PATH="/root/.cargo/bin:$PATH"
fi

# Decide CC + LTO. clang ≥ 8 gets -flto=thin so .a members are emitted as
# LLVM bitcode; older clang or gcc skip it since they don't support thin LTO.
if command -v clang >/dev/null 2>&1 && clang --version 2>&1 | head -1 | grep -qvE 'version (3|4|5|6|7)\.'; then
  STATIC_CC=clang
  STATIC_AR=$(command -v llvm-ar || echo ar)
  STATIC_RANLIB=$(command -v llvm-ranlib || echo ranlib)
  STATIC_LTO_FLAGS="-flto=thin"
elif command -v gcc >/dev/null 2>&1; then
  STATIC_CC=gcc
  STATIC_AR=ar
  STATIC_RANLIB=ranlib
  STATIC_LTO_FLAGS=""
else
  STATIC_CC=cc
  STATIC_AR=ar
  STATIC_RANLIB=ranlib
  STATIC_LTO_FLAGS=""
fi

# Read cflags/<base|os|arch>.txt from the netty-static-jni repo root and thread
# their non-comment, non-blank lines into every Makefile.static invocation as
# USER_CFLAGS. Lets us tweak CFLAGS once per scope (all builds / per-OS /
# per-arch) and have it apply across every platform/target in this build.
USER_CFLAGS=""
CFLAGS_LOADED=()
for cflags_file in \
    "$script_parent/cflags/base.txt" \
    "$script_parent/cflags/$CFLAGS_OS.txt" \
    "$script_parent/cflags/$CFLAGS_ARCH.txt"; do
  [[ -f "$cflags_file" ]] || continue
  flags=$(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/' "$cflags_file" | tr '\n' ' ')
  flags="${flags%% }"
  [[ -z "$flags" ]] && continue
  USER_CFLAGS="${USER_CFLAGS:+$USER_CFLAGS }$flags"
  CFLAGS_LOADED+=("$(basename "$cflags_file")")
done
if [[ -n "$USER_CFLAGS" ]]; then
  echo "==> User CFLAGS from ${CFLAGS_LOADED[*]}: $USER_CFLAGS"
fi

# Skip checkstyle/nohttp/forbiddenapis/revapi across the board: this is a
# downstream staging path, not a release; netty-parent's nohttp-checkstyle-
# validation execution otherwise fails the build over URL-style content in
# unrelated files. Surface the failure flags as a single SKIP_FLAGS string.
SKIP_FLAGS=(
  -Dcheckstyle.skip=true
  -Dnohttp.skip=true
  -Dforbiddenapis.skip=true
  -Drevapi.skip=true
)

if [[ "$PREP" == 1 ]]; then
  echo "==> Installing Java-only sibling modules to ~/.m2 (one-time prep)"
  # Skip:
  #   - all/                       — its mac/linux profiles declare classifier deps without versions (BOM-resolved); fails Maven 3.9.x strict validation when the host's profile activates.
  #   - testsuite-*/               — multiple testsuites hardcode platform-specific classifier deps (e.g. transport-native-epoll:osx-aarch_64) that don't exist on cross hosts.
  #   - native modules themselves  — built in the per-profile loop below, not here.
  # Use `clean install` to wipe any stale target/ (especially important when /code is bind-mounted
  # across host platforms — stale Mac target/ otherwise gets reused by Linux container builds).
  # For Mac cross-arch (mac-intel-cross-compile / mac-m1-cross-compile) pass the
  # profile so transport-native-unix-common produces a matching-arch sibling .a.
  # Otherwise the cross-arch build pulls the host-arch unix-common .a, ar
  # combines arches into a fat archive and llvm-ranlib chokes. For native Linux
  # builds the `linux` profile auto-activates by OS — passing it explicitly
  # additionally activates Maven 3.9.x-strict-rejected version-less classifier
  # deps elsewhere in the reactor (e.g. transport-blockhound-tests), so skip.
  PREP_PROFILE_ARGS=()
  case "$MVN_PROFILE" in
    mac-intel-cross-compile|mac-m1-cross-compile) PREP_PROFILE_ARGS=("-P$MVN_PROFILE") ;;
  esac
  ./mvnw ${PREP_PROFILE_ARGS[@]+"${PREP_PROFILE_ARGS[@]}"} clean install -DskipTests -q "${SKIP_FLAGS[@]}" \
    -pl '!all,!transport-native-epoll,!transport-native-kqueue,!transport-native-io_uring,!codec-native-quic,!resolver-dns-native-macos,!testsuite,!testsuite-autobahn,!testsuite-common,!testsuite-http2,!testsuite-jpms,!testsuite-karaf,!testsuite-native,!testsuite-native-image,!testsuite-native-image-client,!testsuite-native-image-client-runtime-init,!testsuite-osgi,!testsuite-shading'
fi

DEPLOY_REPO="local::default::file://$STAGE"

for m in "${MODULES[@]}"; do
  echo "==> Staging $m (profile=$PROFILE) → $STAGE"
  (
    cd "$m"
    rm -rf target
    # Env vars CC/AR/RANLIB/LTO_FLAGS propagate from this shell → mvn → antrun's
    # <exec> → make, where they win over make's implicit defaults (origin
    # "environment" beats origin "default"). hawtjni's autogen.sh exec works
    # because the rsync above puts source on a non-bind-mount fs where Java's
    # File.setExecutable() actually chmods. -DstaticLib.cc overrides the antrun
    # CC=clang arg in codec-native-quic's build-static-archive (which else
    # passes a hardcoded `clang` that doesn't exist on the gcc-only path).
    CC="$STATIC_CC" LTO_FLAGS="$STATIC_LTO_FLAGS" USER_CFLAGS="$USER_CFLAGS" \
    ../mvnw "-P$MVN_PROFILE" deploy -DskipTests -q "${SKIP_FLAGS[@]}" \
      "-DstaticLib.cc=$STATIC_CC" \
      "-DaltDeploymentRepository=$DEPLOY_REPO"
  )
done

echo
echo "==> Staged artifacts under $STAGE/io/netty:"
find "$STAGE/io/netty" -type f \( -name "*.jar" -o -name "*.pom" \) 2>/dev/null \
  | sort \
  | sed "s|^$STAGE/||"

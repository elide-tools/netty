#!/usr/bin/env bash
# stage-natives-tcnative.sh — build netty-tcnative native + static-archive
# JARs for one platform target and stage them in Maven repo layout under a
# local directory. Sibling to stage-natives.sh (which handles netty itself).
#
# Unlike netty (where one Maven `-P<profile>` covers all modules for a given
# host), tcnative's modules use module-specific profile names: openssl-static
# uses `build-openssl-mac` / `build-openssl-linux`, libressl-static uses
# `build-libressl-non-windows`, boringssl-static uses `boringssl-static-default`,
# etc. So this script accepts a higher-level `<platform>` argument and maps it
# to the per-module profile per the table below.

set -euo pipefail

# Default TCNATIVE_DIR resolution (in priority order):
#   1. Explicit TCNATIVE_DIR env var.
#   2. $script_parent/../netty-tcnative — the canonical layout where this script
#      lives at netty/static-jni/scripts/ and netty-tcnative is symlinked (or
#      submoduled) at netty/netty-tcnative.
#   3. Parent of script dir, IF that parent has mvnw (legacy: script lived in
#      netty-tcnative/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_parent="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -n "${TCNATIVE_DIR:-}" ]]; then
  :
elif [[ -x "$script_parent/../netty-tcnative/mvnw" ]]; then
  TCNATIVE_DIR="$(cd "$script_parent/../netty-tcnative" && pwd)"
elif [[ -x "$script_parent/mvnw" ]]; then
  TCNATIVE_DIR="$script_parent"
else
  TCNATIVE_DIR="$script_parent"
fi

usage() {
  cat <<EOF
Usage: $0 <stage-dir> <platform> [--prep-deps]

  <stage-dir>    Absolute path to a writable directory. Created if missing.
                 Native + static JARs land in Maven repo layout under it.
  <platform>     One of:
                   mac-aarch64    | mac-x86_64
                   linux-x86_64   | linux-aarch64
                 (Windows static archives are deferred — see netty-static-jni
                 specs for the follow-up plan.)
  --prep-deps    Install the openssl-classes Java-only sibling to ~/.m2.
                 Run once per branch update.

Environment:
  TCNATIVE_DIR   Path to the netty-tcnative checkout. Default: $TCNATIVE_DIR
  VERBOSE        When non-empty, drop \`mvn -q\` so make/clang output reaches
                 the terminal — useful for diagnosing static-archive build
                 failures.

Per-platform module → profile mapping:

  mac-aarch64:
    openssl-dynamic   → mac-aarch64
    boringssl-static  → boringssl-static-default
    openssl-static    → build-openssl-mac
    libressl-static   → build-libressl-non-windows

  mac-x86_64:
    openssl-dynamic   → mac-x86_64
    boringssl-static  → mac-intel-cross-compile
    openssl-static    → build-openssl-mac
    libressl-static   → build-libressl-non-windows

  linux-x86_64:
    openssl-dynamic   → (default — no -P)
    boringssl-static  → boringssl-static-default
    openssl-static    → build-openssl-linux
    libressl-static   → build-libressl-non-windows

  linux-aarch64:
    openssl-dynamic   → linux-aarch64
    boringssl-static  → linux-aarch64
    openssl-static    → build-openssl-linux
    libressl-static   → build-libressl-non-windows
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 1
fi

STAGE="$1"
PLATFORM="$2"
shift 2

PREP=0
for arg in "$@"; do
  case "$arg" in
    --prep-deps) PREP=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

# Per-platform per-module build entries. Each entry is "module:profile".
# A trailing colon (`module:`) means "no -P flag" (default activation).
# Scope is intentionally narrow: only boringssl-static is staged. The
# downstream Static-JNI use case (WHIPLASH) only consumes the boringssl-static
# variant; openssl-dynamic / openssl-static / libressl-static were rebuilt
# alongside in earlier iterations but aren't needed.
case "$PLATFORM" in
  mac-aarch64)
    BUILDS=(
      "boringssl-static:boringssl-static-default"
    )
    CFLAGS_OS=darwin; CFLAGS_ARCH=arm64
    ;;
  mac-x86_64)
    BUILDS=(
      "boringssl-static:mac-intel-cross-compile"
    )
    CFLAGS_OS=darwin; CFLAGS_ARCH=amd64
    ;;
  linux-x86_64|linux-aarch64)
    # Native arch build (Alpine on Apple Silicon Docker: linux/arm64 native;
    # linux/amd64 emulated). Default boringssl-static-default profile picks
    # arch via os.detected.arch.
    BUILDS=(
      "boringssl-static:boringssl-static-default"
    )
    CFLAGS_OS=linux
    [[ "$PLATFORM" == "linux-aarch64" ]] && CFLAGS_ARCH=arm64 || CFLAGS_ARCH=amd64
    ;;
  *)
    echo "Unknown platform: $PLATFORM" >&2
    usage >&2
    exit 1
    ;;
esac

# Canonicalize STAGE so altDeploymentRepository receives an absolute file URL.
mkdir -p "$STAGE"
STAGE="$(cd "$STAGE" && pwd)"

if [[ ! -d "$TCNATIVE_DIR" ]]; then
  echo "TCNATIVE_DIR not found: $TCNATIVE_DIR" >&2
  exit 1
fi

# Docker-on-Mac bind mounts make `File.canExecute()` falsely return true,
# which short-circuits hawtjni's `CLI.setExecutable()` so the extracted
# autogen.sh stays 0644 and fails with EACCES. Detect bind-mounted source and
# rsync into a non-bind-mount work dir (the container's overlay fs) before
# building. The output `$STAGE` can stay on the bind mount — only the build
# tree needs `+x` propagation to work.
if [[ -n "${TCNATIVE_REWORK:-}" ]] || \
   ([[ -f /.dockerenv ]] && stat -c %m "$TCNATIVE_DIR" 2>/dev/null | grep -q -v "^/$"); then
  if ! command -v rsync >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache --quiet rsync >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q rsync >/dev/null 2>&1 || true
    fi
  fi
  WORKDIR="${TCNATIVE_REWORK:-/tmp/tcnative-work}"
  echo "==> Copying source from $TCNATIVE_DIR → $WORKDIR (bind-mount workaround)"
  mkdir -p "$WORKDIR"
  ORIG_TCNATIVE_DIR="$TCNATIVE_DIR"
  rsync -a --delete --exclude='target/' --exclude='.git/' \
    "$TCNATIVE_DIR/" "$WORKDIR/"
  # Symlink .git back to the bind-mounted source so write-version-properties
  # antrun can resolve commit hash / status. Mark all dirs as safe.directory
  # so git inside the container (running as root) accepts a repo whose
  # objects are owned by the host uid.
  if [[ -d "$ORIG_TCNATIVE_DIR/.git" ]]; then
    ln -sfn "$ORIG_TCNATIVE_DIR/.git" "$WORKDIR/.git"
    git config --global --add safe.directory '*' >/dev/null 2>&1 || true
  fi
  TCNATIVE_DIR="$WORKDIR"
fi

cd "$TCNATIVE_DIR"

if [[ ! -x ./mvnw ]]; then
  echo "Maven wrapper not found at $TCNATIVE_DIR/mvnw" >&2
  exit 1
fi

# Skip checkstyle/nohttp/forbiddenapis/revapi across the board: this is a
# downstream staging path, not a release; tcnative's release-flavored quality
# checks otherwise gate the build on URL/policy concerns that don't matter for
# binary staging. javadoc/source jar skipped too — openssl-classes' javadoc
# fails on a malformed `{a href=...}` tag, which we don't want to maintain.
# maven.deploy.skip override: upstream openssl-static / libressl-static set it
# to true (and boringssl-static gates it on os.detected.release.like.fedora) so
# Maven Central only sees the linux-x86_64-fedora "blessed" boringssl-static
# jar. We want every platform variant in our local stage, so flip it back on.
SKIP_FLAGS=(
  -Dcheckstyle.skip=true
  -Dnohttp.skip=true
  -Dforbiddenapis.skip=true
  -Drevapi.skip=true
  -Dmaven.javadoc.skip=true
  -Dmaven.source.skip=true
  -Dmaven.deploy.skip=false
  -Denforcer.skip=true
  # xml-maven-plugin's check-format goal occasionally fails to load
  # SAXParserFactory under qemu-aarch64 emulation; skip it (a release-
  # process formatting check, not a correctness gate).
  -Dxml.skip=true
)

# Toolchain setup (mirrors stage-natives.sh):
#   - On Mac, use Apple's clang (already on PATH; supports -flto=thin).
#   - On Alpine Linux (preferred): clang 22 + musl libc. Avoids glibc-specific
#     symbol references like `__strdup` / `__isnan` that show up in the static
#     .a when built against glibc and break downstream musl links. Native arm64
#     under Apple Silicon Docker; emulated for amd64.
#   - AlmaLinux 9 / CentOS 7 paths retained as historical glibc fallbacks.
if command -v apk >/dev/null 2>&1; then
  if ! command -v clang-22 >/dev/null 2>&1; then
    apk add --no-cache --quiet \
      build-base clang22 clang22-extra-tools llvm22 lld22 compiler-rt \
      cmake samurai patch perl perl-utils python3 \
      autoconf automake libtool make git rsync which file linux-headers musl-dev \
      libstdc++-dev apr-dev openssl-dev openjdk17-jdk rust cargo go >/dev/null 2>&1 || true
    [[ -x /usr/bin/samu && ! -e /usr/bin/ninja ]] && ln -sf /usr/bin/samu /usr/bin/ninja
    [[ -x /usr/bin/ninja && ! -e /usr/bin/ninja-build ]] && ln -sf /usr/bin/ninja /usr/bin/ninja-build
  fi
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
    # AlmaLinux 9 (glibc fallback).
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
    [[ -d /usr/include/apr-1 ]] || NEED_DEPS=1
    [[ -d /usr/include/openssl ]] || NEED_DEPS=1
    if [[ "${NEED_DEPS:-0}" == 1 ]]; then
      yum install -y -q epel-release >/dev/null 2>&1 || true
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
      yum install -y -q gcc gcc-c++ libstdc++-static cmake ninja-build patch perl \
        perl-IPC-Cmd perl-Time-Piece autoconf automake libtool make git which \
        apr-devel openssl-devel java-17-openjdk-devel >/dev/null 2>&1 || true
    fi
    if [[ -z "${JAVA_HOME:-}" ]]; then
      if [[ -d /usr/lib/jvm/java-17-openjdk ]]; then
        export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
      else
        JAVA_HOME=$(ls -d /usr/lib/jvm/java-17-openjdk-* 2>/dev/null | head -1)
        [[ -n "$JAVA_HOME" ]] && export JAVA_HOME
      fi
    fi
  else
    # CentOS 7 path (netty:centos-7-1.17 image).
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

# Read cflags/{base,$os,$arch,$os-$arch}.txt from the static-jni dir and thread
# their non-comment, non-blank lines into every Makefile.static invocation as
# USER_CFLAGS. Four scopes, layered most-general first so later scopes win:
#   base.txt           — every build (any os, any arch)
#   $os.txt            — every build on this OS (e.g. all linux)
#   $arch.txt          — every build of this arch (e.g. all arm64)
#   $os-$arch.txt      — only this OS+arch combo (e.g. linux+amd64)
USER_CFLAGS=""
CFLAGS_LOADED=()
for cflags_file in \
    "$script_parent/cflags/base.txt" \
    "$script_parent/cflags/$CFLAGS_OS.txt" \
    "$script_parent/cflags/$CFLAGS_ARCH.txt" \
    "$script_parent/cflags/$CFLAGS_OS-$CFLAGS_ARCH.txt"; do
  [[ -f "$cflags_file" ]] || continue
  flags=$(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/' "$cflags_file" | tr '\n' ' ')
  flags="${flags%% }"
  [[ -z "$flags" ]] && continue
  USER_CFLAGS="${USER_CFLAGS:+$USER_CFLAGS }$flags"
  CFLAGS_LOADED+=("$(basename "$cflags_file")")
done

# Maven verbosity: default to -q so build output stays compact, but allow
# VERBOSE=1 to drop it (and switch to -e) for diagnosing make/clang errors.
if [[ -n "${VERBOSE:-}" ]]; then
  MVN_VERBOSITY=(-e)
else
  MVN_VERBOSITY=(-q)
fi
if [[ -n "$USER_CFLAGS" ]]; then
  echo "==> User CFLAGS from ${CFLAGS_LOADED[*]}: $USER_CFLAGS"
fi

if [[ "$PREP" == 1 ]]; then
  echo "==> Installing openssl-classes (Java-only sibling) to ~/.m2"
  ./mvnw clean install -DskipTests "${MVN_VERBOSITY[@]}" "${SKIP_FLAGS[@]}" -pl 'openssl-classes'
fi

# Forwarded as Maven properties so BoringSSL's cmake invocation and APR's
# configure CFLAGS inherit our LTO + bitcode-indexed-archive choices:
#   exe.cflags.append → appended to BoringSSL's cmakeCFlags / cmakeCxxFlags
#                       and to APR's configure CFLAGS in tcnative parent
#                       pom.xml. USER_CFLAGS already contains -flto=thin
#                       from static-jni/cflags/base.txt.
#   exe.archiver     → AR override (where applicable) so the resulting .a
#                       is bitcode-indexed (default `ar` doesn't know about
#                       the .llvmbc section); STATIC_AR is llvm-ar when
#                       available.
EXTRA_BUILD_PROPS=(
  "-Dexe.cflags.append=$USER_CFLAGS"
  "-Dexe.archiver=$STATIC_AR"
  # Force the compiler to clang since USER_CFLAGS contains clang-specific
  # flags. tcnative's profiles already set clang in some places but the
  # default + several inherit chains can fall back to gcc; pass it
  # everywhere defensively.
  "-Dexe.compiler=$STATIC_CC"
)

# id::layout::url — the legacy 3-token form is required by maven-deploy-plugin
# 2.x, which tcnative pins. Newer (3.x) accepts both.
DEPLOY_REPO="local::default::file://$STAGE"

# Source-build APR (default) so the .o files participate in ThinLTO via
# our USER_CFLAGS plumbing. The system-installed apr-dev package is glibc/ELF
# and not under our control, so falling back to it (the prior
# linkStatic=false / aprHome=/usr override) leaves ~85 .o members as ELF in
# the deliverable. APR_OVERRIDE is left as an empty array so future
# environments can re-introduce a fallback if needed.
APR_OVERRIDE=()

for build in "${BUILDS[@]}"; do
  module="${build%%:*}"
  profile="${build#*:}"
  display_profile="${profile:-default}"
  echo "==> Staging $module (platform=$PLATFORM, profile=$display_profile) → $STAGE"
  (
    cd "$module"
    mvn_args=(clean deploy -DskipTests "${MVN_VERBOSITY[@]}" "${SKIP_FLAGS[@]}"
              "${EXTRA_BUILD_PROPS[@]}"
              ${APR_OVERRIDE[@]+"${APR_OVERRIDE[@]}"}
              "-DaltDeploymentRepository=$DEPLOY_REPO")
    if [[ -n "$profile" ]]; then
      mvn_args=("-P$profile" "${mvn_args[@]}")
    fi
    # Env vars CC/AR/RANLIB/LTO_FLAGS propagate to the build-static-archive
    # antrun's <exec> → make, where they win over make's implicit defaults.
    # Required for -flto=thin (clang only; gcc fallback skips LTO).
    CC="$STATIC_CC" LTO_FLAGS="$STATIC_LTO_FLAGS" USER_CFLAGS="$USER_CFLAGS" \
    ../mvnw "${mvn_args[@]}"
  )
done

echo
echo "==> Staged artifacts under $STAGE/io/netty:"
find "$STAGE/io/netty" -type f \( -name "*.jar" -o -name "*.pom" \) 2>/dev/null \
  | sort \
  | sed "s|^$STAGE/||"

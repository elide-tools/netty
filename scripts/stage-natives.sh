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
#   2. Parent of script dir, IF that parent has mvnw (script lives in netty/scripts/).
#   3. Sibling "netty" directory next to the script's repo (script in netty-static-jni/scripts/,
#      netty checkout next to it).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_parent="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -n "${NETTY_DIR:-}" ]]; then
  : # already set explicitly
elif [[ -x "$script_parent/mvnw" ]]; then
  NETTY_DIR="$script_parent"
elif [[ -x "$script_parent/../netty/mvnw" ]]; then
  NETTY_DIR="$(cd "$script_parent/../netty" && pwd)"
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

# Map profile → modules whose static-jar execution is opted-in for that profile.
case "$PROFILE" in
  mac|mac-m1-cross-compile|mac-intel-cross-compile)
    MODULES=(transport-native-kqueue codec-native-quic resolver-dns-native-macos)
    ;;
  openbsd|freebsd)
    MODULES=(transport-native-kqueue)
    ;;
  linux)
    MODULES=(transport-native-epoll transport-native-io_uring codec-native-quic)
    ;;
  linux-aarch64)
    MODULES=(transport-native-epoll transport-native-io_uring codec-native-quic)
    ;;
  linux-riscv64)
    MODULES=(transport-native-epoll transport-native-io_uring)  # quic has no riscv64
    ;;
  windows)
    # Static JAR for windows-x86_64 is deferred (cmake/msbuild path); this
    # only stages the existing shared-lib classifier JAR for completeness.
    MODULES=(codec-native-quic)
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

cd "$NETTY_DIR"

if [[ ! -x ./mvnw ]]; then
  echo "Maven wrapper not found at $NETTY_DIR/mvnw" >&2
  exit 1
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
  ./mvnw clean install -DskipTests -q "${SKIP_FLAGS[@]}" \
    -pl '!all,!transport-native-epoll,!transport-native-kqueue,!transport-native-io_uring,!codec-native-quic,!resolver-dns-native-macos,!testsuite,!testsuite-autobahn,!testsuite-common,!testsuite-http2,!testsuite-jpms,!testsuite-karaf,!testsuite-native,!testsuite-native-image,!testsuite-native-image-client,!testsuite-native-image-client-runtime-init,!testsuite-osgi,!testsuite-shading'
fi

DEPLOY_REPO="local::default::file://$STAGE"

# The hawtjni-maven-plugin 1.18 extracts a project-template/ from its plugin JAR
# into target/generated-sources/hawtjni/native-package/ at process-classes phase.
# The Java ZIP API drops unix +x bits during extraction, so on Linux (and Linux
# Docker on Mac) the extracted autogen.sh ends up as 0644. hawtjni then tries to
# `./autogen.sh` and hits error=13 Permission denied. Workaround: run hawtjni:generate
# with -Dhawtjni.skipAutogen=true (so it extracts+substitutes templates but skips
# autogen), chmod the script, run autogen ourselves, then run deploy with
# skipAutogen=true again so hawtjni:build proceeds straight to ./configure.
HAWTJNI_AUTOGEN_WORKAROUND="-Dhawtjni.skipAutogen=true"

for m in "${MODULES[@]}"; do
  echo "==> Staging $m (profile=$PROFILE) → $STAGE"
  (
    cd "$m"
    rm -rf target
    # Pass 1: extract+substitute hawtjni templates (no autogen).
    ../mvnw "-P$PROFILE" process-classes -DskipTests -q "${SKIP_FLAGS[@]}" \
      "$HAWTJNI_AUTOGEN_WORKAROUND" >/dev/null
    # chmod and run autogen ourselves so the resulting configure script has
    # the right contents post-template-substitution.
    if [[ -d target/generated-sources/hawtjni/native-package ]]; then
      chmod +x target/generated-sources/hawtjni/native-package/*.sh 2>/dev/null || true
      ( cd target/generated-sources/hawtjni/native-package && ./autogen.sh ) >/dev/null
    fi
    # Pass 2: full deploy. hawtjni:build runs ./configure (already generated)
    # and proceeds to make, then our static-jar antrun runs at package phase.
    ../mvnw "-P$PROFILE" deploy -DskipTests -q "${SKIP_FLAGS[@]}" \
      "$HAWTJNI_AUTOGEN_WORKAROUND" \
      "-DaltDeploymentRepository=$DEPLOY_REPO"
  )
done

echo
echo "==> Staged artifacts under $STAGE/io/netty:"
find "$STAGE/io/netty" -type f \( -name "*.jar" -o -name "*.pom" \) 2>/dev/null \
  | sort \
  | sed "s|^$STAGE/||"

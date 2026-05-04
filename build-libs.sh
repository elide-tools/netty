#!/usr/bin/env bash
#
# Stage transports + tcnative-boringssl-static for all 4 supported platforms:
#   linux/amd64, linux/arm64, macos/arm64, macos/amd64
#
# Linux runs via Alpine + clang 22 + musl in Docker (amd64 emulated on Apple
# Silicon hosts; arm64 native). Mac runs natively against Apple's clang.
#
# Run from inside the netty/ checkout. tcnative lives at netty-tcnative/
# (symlinked to ../netty-tcnative for active local dev) and the staging scripts
# live at static-jni/scripts/.
#
# Comment out individual platforms or modules to subset the build. The first
# invocation per arch passes --prep-deps so the relevant Java siblings (and
# unix-common's matching-arch native bits) land in ~/.m2.

set -euo pipefail

NETTY_DIR="$PWD"
STAGE="$NETTY_DIR/stage"
# Project-local Maven cache, shared across all docker legs. Isolated from
# the host's ~/.m2 so installer/test runs against the host repo can't
# disturb the build cache (and vice versa). Gitignored.
M2="$NETTY_DIR/m2"
STATIC_JNI="$NETTY_DIR/static-jni"
# Resolve the symlink so Docker bind-mounts attach to the real tcnative repo.
TCNATIVE="$(cd "$NETTY_DIR/netty-tcnative" && pwd -P)"

NETTY_SCRIPT="$STATIC_JNI/scripts/stage-natives.sh"
TCNATIVE_SCRIPT="$STATIC_JNI/scripts/stage-natives-tcnative.sh"

mkdir -p "$STAGE" "$M2"

banner() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

# ---- Linux (Alpine + clang 22 + musl, via Docker) -------------------------

linux_build() {
  local platform="$1" profile="$2" script="$3" prep="${4-}"
  docker run --rm \
    --platform="$platform" \
    -e NETTY_DIR=/netty \
    -e TCNATIVE_DIR=/netty-tcnative \
    -v "$NETTY_DIR:/netty" \
    -v "$TCNATIVE:/netty-tcnative" \
    -v "$STAGE:/stage" \
    -v "$M2:/root/.m2" \
    -w /netty \
    --entrypoint /bin/sh \
    alpine:edge \
    -c "apk add --no-cache --quiet bash >/dev/null 2>&1 && $script /stage $profile $prep"
}

# ---- Mac (native, Apple's clang) ------------------------------------------

mac_netty()    { banner "netty $*";    "$NETTY_SCRIPT"    "$STAGE" "$@"; }
mac_tcnative() { banner "tcnative $*"; "$TCNATIVE_SCRIPT" "$STAGE" "$@"; }

# ---- Build matrix ---------------------------------------------------------

# Mac arm64 (host arch on Apple Silicon).
mac_netty    mac --prep-deps
mac_tcnative mac-aarch64

# Mac x86_64 (cross-compile from Apple Silicon — needs --prep-deps for
# transport-native-unix-common to ship a matching osx-x86_64 .a).
mac_netty    mac-intel-cross-compile --prep-deps
mac_tcnative mac-x86_64

# Linux arm64 (native under Apple Silicon Docker).
banner "netty linux/arm64"
linux_build linux/arm64 linux-aarch64 /netty/static-jni/scripts/stage-natives.sh --prep-deps
banner "tcnative linux/arm64"
linux_build linux/arm64 linux-aarch64 /netty/static-jni/scripts/stage-natives-tcnative.sh

# Linux amd64 (emulated under QEMU on Apple Silicon — slowest leg).
banner "netty linux/amd64"
linux_build linux/amd64 linux         /netty/static-jni/scripts/stage-natives.sh --prep-deps
banner "tcnative linux/amd64"
linux_build linux/amd64 linux-x86_64  /netty/static-jni/scripts/stage-natives-tcnative.sh

banner "All artifacts staged under $STAGE/io/netty"

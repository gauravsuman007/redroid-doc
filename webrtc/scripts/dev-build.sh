#!/bin/bash
# Development build of the redroid WebRTC streamer and the cuttlefish operator,
# run on a Linux host (e.g. the Lima VM). Produces a runnable tree in $OUT:
#   $OUT/bin/redroid_webrtc, $OUT/bin/operator,
#   $OUT/html_client/ (device page), $OUT/operator/{static,intercept}/
#
# Usage: webrtc/scripts/dev-build.sh [cuttlefish-checkout] [out-dir]
set -euo pipefail

WEBRTC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CF_SRC="${1:-$HOME/src/android-cuttlefish}"
OUT="${2:-$HOME/redroid-webrtc}"
CF_COMMIT="$(cat "$WEBRTC_DIR/CUTTLEFISH_VERSION")"
# Extra bazel flags, e.g. BAZEL_FLAGS="--jobs=4" on small hosts (~/.bazelrc also applies).
read -r -a BAZEL_FLAGS <<< "${BAZEL_FLAGS:-}"

if [ ! -d "$CF_SRC/.git" ]; then
  git clone --filter=blob:none https://github.com/google/android-cuttlefish.git "$CF_SRC"
fi
if [ "$(git -C "$CF_SRC" rev-parse HEAD)" != "$CF_COMMIT" ]; then
  git -C "$CF_SRC" fetch origin "$CF_COMMIT"
  git -C "$CF_SRC" checkout --detach "$CF_COMMIT"
fi

# Apply patches idempotently.
for p in "$WEBRTC_DIR"/patches/*.patch; do
  if git -C "$CF_SRC" apply --check "$p" 2>/dev/null; then
    echo "Applying $(basename "$p")"
    git -C "$CF_SRC" apply "$p"
  elif git -C "$CF_SRC" apply --reverse --check "$p" 2>/dev/null; then
    echo "Already applied: $(basename "$p")"
  else
    echo "Patch does not apply: $p" >&2
    exit 1
  fi
done

# Our sources live in the cuttlefish tree so they can depend on libdevice.
PKG="$CF_SRC/base/cvd/cuttlefish/host/frontend/redroid_webrtc"
rm -rf "$PKG"
mkdir -p "$PKG"
cp "$WEBRTC_DIR"/streamer/*.{h,cpp} "$WEBRTC_DIR"/streamer/BUILD.bazel "$PKG"/

(cd "$CF_SRC/base/cvd" &&
  bazel build ${BAZEL_FLAGS[@]+"${BAZEL_FLAGS[@]}"} //cuttlefish/host/frontend/redroid_webrtc:redroid_webrtc)

(cd "$CF_SRC/frontend/src/operator" && go build -o "$CF_SRC/frontend/out/operator" .)

mkdir -p "$OUT/bin" "$OUT/operator/static" "$OUT/operator/intercept"
install -m 0755 "$CF_SRC/base/cvd/bazel-bin/cuttlefish/host/frontend/redroid_webrtc/redroid_webrtc" "$OUT/bin/"
install -m 0755 "$CF_SRC/frontend/out/operator" "$OUT/bin/"
rm -rf "$OUT/html_client"
cp -r "$CF_SRC/base/cvd/cuttlefish/host/frontend/webrtc/html_client" "$OUT/html_client"
rm -f "$OUT/html_client/BUILD.bazel"
cp -r "$CF_SRC/frontend/src/operator/intercept/." "$OUT/operator/intercept/"
echo "Built into $OUT"

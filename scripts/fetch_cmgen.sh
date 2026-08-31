#!/usr/bin/env bash
# Fetch Filament's prebuilt host tools (cmgen — the IBL prefilter) and
# vendor the binary into vendor/filament-tools/ (gitignored).
#
# cmgen ships inside the per-OS Filament release tgz (bin/cmgen); there is
# no standalone download. The version pin lives in priv/filament-version —
# the single authority, read at compile time by Mob.Scene3d.Assets for its
# install guidance and by this script (lockstep test: assets_test.exs).
#
# Same fetch pattern as the spike's s3d_spike/scripts/fetch_filament_ios.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILAMENT_VERSION="$(tr -d '[:space:]' < "$ROOT/priv/filament-version")"
DEST="$ROOT/vendor/filament-tools"

case "$(uname -s)" in
  Darwin) OS_TAG="mac" ;;
  Linux)  OS_TAG="linux" ;;
  *) echo "error: unsupported host OS $(uname -s) — download Filament ${FILAMENT_VERSION} manually from https://github.com/google/filament/releases" >&2
     exit 1 ;;
esac

if [ -x "$DEST/cmgen" ]; then
  echo "cmgen already vendored at $DEST/cmgen"
  exit 0
fi

URL="https://github.com/google/filament/releases/download/${FILAMENT_VERSION}/filament-${FILAMENT_VERSION}-${OS_TAG}.tgz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL ..."
curl -sfL -o "$TMP/filament.tgz" "$URL"
tar xzf "$TMP/filament.tgz" -C "$TMP" filament/bin/cmgen filament/LICENSE

mkdir -p "$DEST"
cp "$TMP/filament/bin/cmgen" "$DEST/cmgen"
cp "$TMP/filament/LICENSE" "$DEST/LICENSE"
chmod +x "$DEST/cmgen"

echo "Vendored cmgen (Filament ${FILAMENT_VERSION}) at $DEST/cmgen"
"$DEST/cmgen" --version || true

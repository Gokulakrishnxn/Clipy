#!/usr/bin/env bash
# Build Clipy locally and install it through Homebrew, without a published
# release. Creates a *local* tap named gokulakrishnxn/clipy (same name as the
# future GitHub tap) whose cask points at the local DMG via file://, so the
# install command is identical to the public one:
#
#   brew install --cask gokulakrishnxn/clipy/clipy
#
#   scripts/brew-local.sh                # build DMG (native arch) → brew install
#   scripts/brew-local.sh --skip-build   # reuse dist/Clipy-<v>.dmg
#
# `brew uninstall|reinstall|zap --cask clipy` work as usual. To switch to the
# published tap later: `brew untap gokulakrishnxn/clipy` then install again.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }
[[ "${1:-}" == "--skip-build" ]] || scripts/build-macos.sh --dmg

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -n1)
DMG="$PWD/dist/Clipy-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "missing $DMG"; exit 1; }
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

TAP=gokulakrishnxn/clipy
TAP_DIR="$(brew --repository)/Library/Taps/gokulakrishnxn/homebrew-clipy"
if [[ ! -d "$TAP_DIR" ]]; then
  echo "▸ brew tap-new $TAP (local)"
  brew tap-new --no-git "$TAP" >/dev/null
elif [[ -d "$TAP_DIR/.git" ]] && git -C "$TAP_DIR" remote get-url origin 2>/dev/null | grep -q github.com; then
  echo "$TAP is the published GitHub tap; run 'brew untap $TAP' first to use a local build."; exit 1
fi
mkdir -p "$TAP_DIR/Casks"
sed -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" \
    -e "s|^  url \".*\",\$|  url \"file://${DMG}\"|" \
    -e '/^      verified: /d' \
    -e '/^  livecheck do/,/^  end/d' \
    packaging/homebrew/Casks/clipy.rb > "$TAP_DIR/Casks/clipy.rb"

echo "▸ brew install --cask $TAP/clipy"
brew uninstall --cask clipy >/dev/null 2>&1 || true
brew install --cask "$TAP/clipy"
open -a Clipy
echo "✓ installed via Homebrew (local tap $TAP). Manage with: brew {list|reinstall|uninstall|zap} --cask clipy"

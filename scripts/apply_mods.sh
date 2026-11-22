#!/usr/bin/env bash
# Apply the mod-gifts patch and copy the new module files into a Telegram-iOS checkout.
# Usage: apply_mods.sh <telegram-ios-source-dir> <ci-repo-dir>
set -euo pipefail

SOURCE_DIR="$1"
REPO_DIR="$2"

echo "Applying mod-gifts patch to $SOURCE_DIR"
# --check first so a mismatched upstream ref fails loudly instead of applying with fuzz.
git -C "$SOURCE_DIR" apply --check "$REPO_DIR/patches/mod-gifts.patch"
git -C "$SOURCE_DIR" apply "$REPO_DIR/patches/mod-gifts.patch"

echo "Copying new module files"
# newfiles/ mirrors the repo layout; copy each file into place.
(cd "$REPO_DIR/newfiles" && find . -type f -print0) | while IFS= read -r -d '' rel; do
  rel="${rel#./}"
  mkdir -p "$SOURCE_DIR/$(dirname "$rel")"
  cp "$REPO_DIR/newfiles/$rel" "$SOURCE_DIR/$rel"
  echo "  + $rel"
done

echo "Mod applied."

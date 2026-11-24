#!/bin/zsh
# Installs or updates Knob from GitHub in one go:
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/TKBuildsApps/knob/main/get.sh)"
# Keeps the source in ~/knob (or $KNOB_DIR), then runs its installer. Run it again to update.
set -euo pipefail

DIR="${KNOB_DIR:-$HOME/knob}"
REPO=https://github.com/TKBuildsApps/knob.git

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Knob is built from source and needs Apple's command line tools."
  xcode-select --install 2>/dev/null || true
  echo "Finish installing them in the window that opened, then run this command again."
  exit 1
fi

if [[ -d "$DIR/.git" ]]; then
  if [[ "$(git -C "$DIR" remote get-url origin 2>/dev/null)" != */TKBuildsApps/knob* ]]; then
    echo "$DIR is a different project, not Knob. Move it, or choose another folder with KNOB_DIR=…"
    exit 1
  fi
  echo "Updating Knob in $DIR…"
  git -C "$DIR" pull --ff-only --quiet
elif [[ -e "$DIR" ]]; then
  echo "$DIR already exists and isn't Knob. Move it, or choose another folder with KNOB_DIR=…"
  exit 1
else
  echo "Downloading Knob to $DIR…"
  git clone --depth 1 --quiet "$REPO" "$DIR"
fi

exec "$DIR/install.sh" "$@"

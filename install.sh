#!/bin/bash
# Installs (or reinstalls) CountdownOverlay.app into ~/Applications, then opens it. After this,
# updates come from the menu-bar icon (right-click → Check for Updates…).
#
#   curl -fsSL https://raw.githubusercontent.com/ainigh/ONE-FILE-SWIFT/main/install.sh | bash
#
# It takes the latest release GitHub built. If there isn't one (or FROM_SOURCE=1), it downloads
# the source of main (BRANCH=name for another branch) and builds it here with Apple's command
# line tools. The app then follows that branch for updates.
set -euo pipefail

REPO="ainigh/ONE-FILE-SWIFT"
BRANCH="${BRANCH:-main}"
APPS="${HOME:?}/Applications"
NAME="CountdownOverlay"
API="https://api.github.com/repos/$REPO"
INSTALLED="${APPS:?}/${NAME:?}.app"
PREVIOUS="${APPS:?}/.${NAME:?}-previous.app"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == Darwin ]] || die "$NAME is a Mac app (macOS 11 or newer)."
major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$major" -ge 11 ]] || die "$NAME needs macOS 11 or newer; this Mac has $(sw_vers -productVersion)."

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT

# the app: GitHub's build, else built here -----------------------------------------------------
app=""
if [[ "${FROM_SOURCE:-0}" != 1 && "$BRANCH" == main ]]; then
  say "Downloading the latest release"
  url="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API/releases/latest" 2>/dev/null \
         | grep -o '"browser_download_url": *"[^"]*'"$NAME"'\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/' || true)"
  if [[ -n "$url" ]] && curl -fsSL -o "$tmp/$NAME.zip" "$url"; then
    ditto -x -k "$tmp/$NAME.zip" "$tmp/unpacked"
    app="$tmp/unpacked/$NAME.app"
  else
    echo "  No release yet: building it here instead."
  fi
fi

if [[ -z "$app" ]]; then
  xcode-select -p >/dev/null 2>&1 || die "Building needs Apple's command line tools: run xcode-select --install, then this again."
  sha="$(curl -fsSL -H 'Accept: application/vnd.github.sha' "$API/commits/$BRANCH")" || die "Couldn't find the branch $BRANCH."
  say "Downloading the source ($BRANCH, ${sha:0:7})"
  mkdir -p "$tmp/src"
  curl -fsSL -o "$tmp/src.tar.gz" "https://codeload.github.com/$REPO/tar.gz/$sha"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components 1
  say "Building"
  (cd "$tmp/src" && VERSION="1.0-${sha:0:7}" COMMIT="$sha" BRANCH="$BRANCH" scripts/make-app.sh)
  app="$tmp/src/build/$NAME.app"
fi

# install and open -----------------------------------------------------------------------------
# The copy that was here is kept until the new one is seen running: if the new one quits straight
# away, the old one goes back and opens again.
say "Installing into $APPS"
[[ -d "$app" ]] || die "The download didn't hold $NAME.app."
pkill -x "$NAME" 2>/dev/null && sleep 1 || true
mkdir -p "$APPS"
rm -rf "$PREVIOUS"
[[ -d "$INSTALLED" ]] && mv "$INSTALLED" "$PREVIOUS"
ditto "$app" "$INSTALLED"
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
version="$(defaults read "$INSTALLED/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
open "$INSTALLED"

started=0
for _ in 1 2 3 4 5; do
  sleep 1
  if pgrep -x "$NAME" >/dev/null; then started=1; else started=0; fi
done
if [[ "$started" == 1 ]]; then
  rm -rf "$PREVIOUS"
  say "Done ($NAME $version): look for the timer icon in the menu bar."
  exit 0
fi

crash="$(ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i "$NAME" | head -1 || true)"
if [[ -d "$PREVIOUS" ]]; then
  rm -rf "$INSTALLED"
  mv "$PREVIOUS" "$INSTALLED"
  open "$INSTALLED"
  printf '\n\033[31m%s\033[0m\n' "$NAME $version quit as soon as it opened, so the one you had is back and open again." >&2
else
  printf '\n\033[31m%s\033[0m\n' "$NAME $version quit as soon as it opened." >&2
fi
[[ -n "$crash" ]] && echo "  What went wrong is in ~/Library/Logs/DiagnosticReports/$crash" >&2
echo "  To see it happen: $INSTALLED/Contents/MacOS/$NAME" >&2
exit 1

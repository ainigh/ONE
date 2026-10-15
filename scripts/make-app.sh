#!/bin/bash
# Builds build/CountdownOverlay.app and build/CountdownOverlay.zip (what a release carries) from
# the single main.swift. Needs a Mac with Apple's command line tools (xcode-select --install).
#
#   scripts/make-app.sh                            a local build
#   VERSION=1.0.7 BRANCH=main scripts/make-app.sh  what CI and the in-app updater run
#
# Environment:
#   VERSION         CFBundleShortVersionString (default: from Info.plist, e.g. 1.0)
#   COMMIT          the commit it was built from (default: git HEAD, if this is a checkout)
#   BRANCH          the branch the in-app updater follows (default: main)
#   UNIVERSAL=1     arm64 + x86_64 (CI); default builds only this Mac's architecture
#   SIGN_IDENTITY   a code-signing identity from your keychain. Optional: without one the app is
#                   ad-hoc signed with a designated requirement of just its bundle identifier, so
#                   macOS treats every update as the same app.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=CountdownOverlay
APP="build/$NAME.app"
MIN_MACOS=11.0
PB=/usr/libexec/PlistBuddy
PLIST_VERSION="$($PB -c 'Print CFBundleShortVersionString' Info.plist 2>/dev/null || echo 1.0)"
VERSION="${VERSION:-$PLIST_VERSION}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
BRANCH="${BRANCH:-main}"

if [ "$(uname)" != "Darwin" ]; then
  echo "error: make-app.sh must run on macOS (this is $(uname))." >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "error: building needs Apple's command line tools: run xcode-select --install" >&2
  exit 3
fi

rm -rf ./build
mkdir -p build/obj

compile() { # compile <arch> <output>
  echo "==> swiftc ($1)"
  swiftc -O -target "$1-apple-macos$MIN_MACOS" -framework Cocoa -o "$2" main.swift
}

if [ "${UNIVERSAL:-0}" = 1 ]; then
  compile arm64 "build/obj/$NAME-arm64"
  compile x86_64 "build/obj/$NAME-x86_64"
  lipo -create -output "build/obj/$NAME" "build/obj/$NAME-arm64" "build/obj/$NAME-x86_64"
else
  compile "$(uname -m)" "build/obj/$NAME"
fi

echo "==> assembling $APP ($VERSION, $BRANCH, ${COMMIT:0:7})"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/obj/$NAME" "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
$PB -c "Add :CountdownCommit string $COMMIT" "$APP/Contents/Info.plist"
$PB -c "Add :CountdownBranch string $BRANCH" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
rm -rf ./build/obj

BUNDLE_ID="$($PB -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> signing with \"$SIGN_IDENTITY\""
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
else
  # An ad-hoc signature's default designated requirement is the binary's hash, which changes with
  # every build. Requiring only the bundle identifier keeps macOS treating updates as the same app.
  echo "==> ad-hoc signing ($BUNDLE_ID, identifier-only requirement)"
  codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
codesign --verify --verbose=1 "$APP"

ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "==> built $(pwd)/$APP ($VERSION, $BRANCH, ${COMMIT:0:7})"

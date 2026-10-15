# CountdownOverlay

Menubar app: click the timer icon → every connected screen is covered by a
dark overlay with a 5-second countdown in the center. Esc, Cmd-W, Cmd-Q and
clicks are swallowed while it runs; it dismisses itself at 0.

The whole app is one Swift file, `main.swift`.

## Install

Paste this in Terminal (macOS 11 or newer):

```sh
curl -fsSL https://raw.githubusercontent.com/ainigh/ONE-FILE-SWIFT/main/install.sh | bash
```

It downloads the latest release into `~/Applications/CountdownOverlay.app` and opens it. If
there's no release yet (GitHub Actions hasn't built one), it builds from the source instead,
which needs Apple's command line tools (`xcode-select --install`). If the new copy quits as soon
as it opens, the installer puts the one you had back. Running the line again is always safe.

To install a branch that isn't merged yet, and follow that branch for updates:

```sh
curl -fsSL "https://raw.githubusercontent.com/ainigh/ONE-FILE-SWIFT/BRANCH/install.sh" | BRANCH=BRANCH bash
```

## Updates

The app follows `main` (or the branch it was installed from). It checks at launch, every 6
hours, and when you choose **Check for Updates…** in the right-click menu, which always shows the
version and commit you're on. When the branch has a commit this copy wasn't built from, the menu
offers:

- **Update to v1.0.N**: GitHub already built that commit. The app downloads it, swaps itself and
  reopens.
- **Update (build here)**: GitHub hasn't built it yet. The app downloads that commit's source,
  builds it on this Mac, swaps itself and reopens. Build output goes to
  `~/Library/Logs/CountdownOverlay/update.log`.

Updating is offered only between countdowns, since it restarts the app. If an update fails,
**Copy Update Details** copies the error and the end of the log.

GitHub Actions (`.github/workflows/build.yml`) builds every push and publishes a release
(`v1.0.<run number>`, with `CountdownOverlay.zip`) for every push to `main`.

The app is ad-hoc signed with a requirement of just its bundle identifier
(`com.ainigh.CountdownOverlay`), so macOS treats every update as the same app. To sign with your
own certificate instead, run
`defaults write com.ainigh.CountdownOverlay signIdentity "THE CERTIFICATE NAME"` once; updates
built on your Mac are then signed with it.

## Build it yourself (no Xcode project needed)

```sh
make app      # builds build/CountdownOverlay.app (and build/CountdownOverlay.zip)
make install  # copies it into ~/Applications and opens it
make run      # builds and opens it from build/
```

Or just the bare binary, which still works but doesn't check for updates:

```sh
swiftc -O -o CountdownOverlay main.swift -framework Cocoa
./CountdownOverlay
```

Requires Xcode command line tools (`xcode-select --install`), macOS 11+.

## Use

- **Left-click** the menubar icon → start countdown.
- **Right-click** → menu with Start / version / updates / Quit (Start, Update and Quit are
  disabled during a countdown).
- The length defaults to 5 seconds. Override it per launch with an argument
  or an environment variable (argument wins; values outside 1–3600 fall back
  to the default). `-h` / `--help` prints usage, `--version` the version and commit.

  ```sh
  ./CountdownOverlay -duration 10
  COUNTDOWN_SECONDS=10 ./CountdownOverlay
  ```

## Robustness notes

- The count is derived from a deadline, not a once-per-second tick, so it
  never drifts and resolves correctly if the Mac sleeps mid-countdown.
- All key events to the process are swallowed by a local event monitor, and
  the app re-activates itself if it loses focus, so Cmd-Q / Esc can't slip
  through via another window.
- Overlays are rebuilt (coalesced, after a short delay) when displays are
  added, removed or resized, and placed in global coordinates so secondary
  displays are covered correctly.
- The cursor is hidden and the menubar icon dims while the countdown runs.
- The digits scale with the smallest screen dimension.
- Focus returns to the app that was frontmost before the countdown started.

## What can't be blocked

Cmd-Option-Esc (Force Quit), Mission Control gestures and the power button are
reserved by macOS. For a 5-second overlay that's acceptable; the app simply
makes casual dismissal (Esc, click, Cmd-Q) impossible.

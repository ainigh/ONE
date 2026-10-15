# Opened / Closed Timer — Specification

## 1. Overview

A session alternates between two modes. The cycle cannot be stopped or shortened by the user except through the escape puzzle (§6).

| Mode | Screen | Timer |
|---|---|---|
| **Opened** | Not blocked | Counts down |
| **Closed** | Blocked | Counts down |

Every mode change passes through a confirmation (§3). Nothing runs until the user responds.

## 2. Durations

- Allowed slot values: **4, 8, 16 minutes**.
- Each mode has its own slot. Defaults: Opened = 16, Closed = 4.
- The slot can be changed on the confirmation box. A change applies to **the mode about to start**.
- Only one user-initiated duration path exists; there is no snooze, extend, or skip.

## 3. Confirmation

Shown before every mode change, including the first mode of a session. The timer is frozen while it is displayed; the screen is blocked.

**Content**
- Heading: *"Ready to switch to Closed?"* / *"Ready to switch to Opened?"* (first time: *"Ready to start?"*)
- Slot selector for the mode about to start: `4` `8` `16`, current value highlighted.
- One button: **Start**.

**Behavior**
- There is no decline option. The only way forward is Start.
- No timeout. If unanswered, the screen stays blocked indefinitely.

## 4. Session

- Activation shows the first confirmation immediately. The first mode is **Opened**.
- At activation the user picks a session length: **10 min, 1 h, 2 h, 4 h, 8 h**. (Chosen for you — some end condition is required or the session never terminates. 10 minutes is for trying the flow: with 4-minute slots it runs Opened, Closed, then Opened again before the session ends at the next confirmation.)
- The session ends at the first confirmation reached after the session length has elapsed. The timer never ends mid-mode.
- The session cannot be ended or paused by any other control.

## 5. Reminders

In both modes, a reminder states the time remaining. Reminders fire at halving intervals of the slot, dropping any that would fall under 1 minute from the end.

| Slot | Reminders at (time left) |
|---|---|
| 16 | 8:00, 4:00, 2:00, 1:00 |
| 8 | 4:00, 2:00, 1:00 |
| 4 | 2:00, 1:00 |

- In both modes, a pop-up in the middle of every screen, above everything (the blocked screen included), with the time left and the mode. It never takes the keyboard and goes away by itself after a few seconds, or at a click. Closed also keeps the reminder in the strip on the blocked screen.
- Reminders are informational only; they contain no controls and no puzzle.

## 6. Escape puzzle (Closed mode only)

The only way to leave Closed early.

- The blocked screen shows a persistent **I need out** button.
- Pressing it shows a prime-arithmetic puzzle: two random primes below 50 and an operation (sum or product), e.g. *"23 × 7 = ?"*. Answer is a whole number typed into a single field.
- **Correct** → operations pause for **20 minutes** (§7).
- **Wrong** → up to 3 attempts; after the third, the puzzle closes and the button is disabled for 2 minutes. The block timer keeps running throughout.
- **Cooldown**: one successful escape per 60 minutes, measured from the last successful escape. The button is hidden while on cooldown.
- The puzzle is friction, not security. A second device defeats it; that is accepted.

## 7. Pause

- Duration: 20 minutes, fixed. Screen unblocked, all timers frozen.
- When it ends, the app goes straight to a confirmation for **Closed with its full slot**. The interrupted block does not resume partially; it restarts.
- The pause counts toward the session length.

## 8. Edge rules

- Durations are always shown as `mm:ss`.
- No action is available during a mode except the escape button and the canvas in Closed (§10).
- If the app is killed or the device restarts mid-session, it reopens to a confirmation for the mode that was interrupted, with its full slot.

## 9. Sounds

A short system sound marks every transition point, so the user hears a change without looking.

| Transition | Sound |
|---|---|
| A confirmation box appears (a mode is about to change, §3) | Glass |
| Opened starts | Hero |
| Closed starts | Submarine |
| A reminder fires (§5) | Tink |
| A wrong puzzle answer (§6) | Basso |
| The puzzle is solved and the pause begins (§7) | Pop |
| The pause ends | Blow |
| The session ends (§4) | Funk |

- Sounds are the macOS system sounds of those names; a missing one is simply silent.
- They play louder than the system plays them: 18 dB of gain followed by a peak limiter, so they don't distort (`soundBoost`, 0–24 dB). The reminder (Tink) and the solved puzzle (Pop) play three times in a row, since one is too short to notice.
- Sounds are informational only and never replace the confirmation or a reminder's text.
- Launching with `-mute YES` silences all of them.

## 10. Canvas

What blocks the screen in Closed is a canvas the user writes on (`Canvas.html`). It is also there whenever the screen isn't blocked, from its own menu-bar icon.

- The canvas is infinite: drag empty space or scroll to move around, pinch or ⌘-scroll to zoom.
- On it are surfaces, written on directly (no separate edit mode). A surface can be dragged by its edge or its strip, resized from its corner, given one of twelve colours (or none), and deleted (a surface with text asks for a second click, and can be brought back for a few seconds after).
- Double-clicking empty space starts a surface there; one left empty and untouched goes away again when you click elsewhere.
- When the screen isn't blocked, the canvas icon (or **Open Canvas** in the timer's menu) opens it in an ordinary window, which the user can close at any time. Clicking the icon again closes it.
- When the screen is blocked, the canvas moves into the overlay and cannot be closed; an open window steps aside and comes back when the block ends.

- On the main screen (the one with the menu bar), Closed shows the canvas full screen, under a strip with the time left, the reminders (§5) and **I need out** (§6). Other screens keep the dark blocked screen.
- Confirmations (§3) and the puzzle (§6) cover the canvas while they show; it comes back as it was.
- The surfaces are kept on the Mac (`~/Library/Application Support/CountdownOverlay/canvas.json`) and carry over from one Closed to the next, and across sessions.
- The canvas is a place to think, not a way out: it has no links, and leaves the block timer running.
- If the page is missing (a bare binary run away from the source), Closed shows the dark blocked screen.

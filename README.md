# Earshot

**Listen instead of read.** A macOS menu bar app that reads any text aloud — web pages, mail, docs, PDFs — in a natural local voice, at high speed, only into your headphones.

## Highlights

| | |
|---|---|
| Point and tap | Four-finger tap on the trackpad reads the paragraph under the pointer. Double-tap reads from there to the end. No selecting. |
| Works everywhere | One app for every program, including browsers (Safari, Chrome, Brave, Arc, Edge) — no extension. Falls back to on-screen OCR for images and PDFs. |
| Natural and fast | Kokoro-82M runs locally on Apple Silicon (~12× real time, first words in ~0.3 s). 28 English voices, 0.7–4× speed. Apple voices as a fallback. |
| Headphones only | Never speaks on the Mac speakers unless you allow it. Pauses when headphones disconnect, resumes when they're back. |
| Notification announcer | "WhatsApp. Rahul. Read it?" — answer yes/no by voice, a four-finger tap or ⌃⌥N. Short messages are read straight away, long ones summarized on-device first (Apple Intelligence). Per-app rules and quiet hours. |
| Gist first | A 3–5 sentence spoken summary of any page or selection from Apple's on-device model (long pages summarized section by section), then "Read the whole page?" — starting at the article, not the site menu. |
| Auto-read | New text on chosen sites or apps — a chat reply, a new message, a search answer — is read once it stops changing. ⌃⌥L pins any page. Your own typing is never read. |
| Media aware | Turns every other app down while speaking (videos in your browser, Spotify, calls) and fades it back up — or pauses and resumes, if you prefer. Optional volume boost above 100%. |
| Yours to tune | Every shortcut and gesture is rebindable; voice, speed, volume, output devices and text cleanup are in Settings. |

## Default controls

| Action | Shortcut | Gesture |
|---|---|---|
| Read selection, or paragraph under pointer | ⌃⌥R | 4-finger tap (paragraph) |
| Read from pointer to the end | ⌃⌥A | 4-finger double-tap |
| Read the whole window | ⌃⌥W | |
| Pause / resume | ⌃⌥P | 3-finger double-tap |
| Stop | ⌃⌥S or Esc while reading | 5-finger tap |
| Next / previous sentence | ⌃⌥→ / ⌃⌥← | |
| Faster / slower | ⌃⌥↑ / ⌃⌥↓ | |
| Summarize the page (or selection), then offer to read it | ⌃⌥G | 4-finger triple-tap |
| Read latest notification / answer "yes" | ⌃⌥N | 4-finger tap while it asks |

## Install from source

```bash
scripts/install-engine.sh          # Kokoro engine → ~/Library/Application Support/Earshot/engine (needs uv)
cd app && scripts/bundle.sh release
ditto build/Earshot.app /Applications/Earshot.app
```

Grant **Accessibility** (required) and optionally **Screen Recording** (OCR fallback) in Earshot → Settings → General.

## How it works

- `engine/server.py` — resident Kokoro (MLX) process; the app talks to it over stdio, one sentence per request, a few sentences ahead.
- `app/Sources/Earshot/TextGrabber.swift` — Accessibility text markers for web content, character ranges for native text views, OCR (Vision) as fallback.
- `app/Sources/Earshot/Trackpad.swift` — raw multitouch frames → `TapRecognizer`.
- `app/Sources/Earshot/NotificationWatcher.swift` — new Notification Center banners via Accessibility (the notification database is locked on macOS 26); `Announcer.swift` decides what to say; `VoiceReply.swift` hears yes/no on-device with the built-in mic.
- `app/Sources/Earshot/AudioOutput.swift` / `MediaControl.swift` — output policy, device routing, pausing other audio.
- `app/Sources/Earshot/Ducker.swift` — a Core Audio process tap of everything except Earshot ("muted when tapped") replayed through a private aggregate device at a ramped gain.

## Privacy

Everything runs on your Mac. No text or audio leaves it. Logs: `~/Library/Logs/Earshot/earshot.log`.

## License

MIT

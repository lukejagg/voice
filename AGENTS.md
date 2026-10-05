# Voice

Voice is a native macOS dictation app. Its UI should feel quiet and finished: neutral surfaces, generous space, clear typography, and only the controls needed for the current task. ChatGPT's restraint is the visual reference, not an invitation to add chat features.

## Project rules

- Load `OPENAI_API_KEY` from `~/secrets/openai.env`. Never print the secret, embed it in source, bundle it, or put it in documentation, logs, fixtures, or screenshots.
- `README.md` is the explicitly requested public product overview. Keep maintainer instructions and additional project documentation in `AGENTS.md`.
- Keep the app single-instance per user. Preserve the OS lock through the entire application run loop. Duplicate launches must exit before creating windows, event taps, or recorders. Do not replace atomic locking with a process-name check.
- Preserve real recordings on finish, cancellation, quit, and failure. Only the tentative recording created by the first tap of a double-tap gesture may be discarded.

## UI principles

- No instructional paragraphs, slogans, redundant headings, subheadings, model names, implementation details, success banners, or repeated controls inside the app.
- Recording panel: waveform/recording indicator, a restrained sound level display, elapsed time immediately to the left of the top-right X. The X quits Voice, finalizes active audio locally, and cancels pending work. No Stop, Cancel, Done, Copy, or Dismiss buttons in this panel. Right Option is the primary control.
- Start audio capture immediately on the first bare right Option release, with no double-tap waiting period. Begin capture before fading the panel in. Animation must never delay recording or the transcription request.
- Finishing a recording immediately frees capture and fades the panel into the neutral/hidden state. Transcription and paste run in the background. Do not gate right Option on network work or keep a blocking progress panel open. A new recording fades in immediately, even while older recordings are processing.
- On successful transcription, save the result, copy it, and paste when permitted without changing the current recording’s UI. An older success/failure must never dismiss or replace a newer recording’s panel. Never display “Pasted”, “Copied”, “Saved”, “Ready”, or an extra completion state.
- Quitting cancels pending work without a confirmation state. Failures remain retryable in history; a short actionable status may appear only when no newer recording is active. Do not hide errors as though they were successful operations.
- Use short, interruptible fades and smooth state transitions (roughly 160–220 ms). Respect Reduce Motion. A new recording must not be hidden by an earlier fade's completion callback.
- The panel is nonactivating and cannot become key/main. Showing it and clicking X must not deselect the user's current text field. Do not activate Voice to record or paste.
- History is a quiet native window: one search field, plain transcript rows, muted date/duration, subtle separators, and small play/copy/retry icons. Click a transcript to copy. A brief checkmark is enough feedback. No teaching text, decorative cards, marketing headers, or duplicate labeled action bars.
- Permissions show only the three required permission rows and the necessary Enable actions. No onboarding pitch or tutorial.
- Prefer native SF Symbols, semantic colors, system typography, neutral materials, and subtle borders. Avoid bright accent blocks, saturated status colors, excessive shadows, ornamental graphics, or unnecessary gradients.
- Support light and dark appearance, readable contrast, accessible names for icon buttons, hover feedback, and keyboard/native window behavior. Minimalism must not remove an essential permission or failure state.

## Sound principles

- Use only the two original, locally synthesized cues in `Assets/Sounds/`; no stock macOS sounds or sample-library notifications.
- Both sounds share a soft felt/glass timbre and a D-major palette. Start rises from D5 to A5 (360 ms). Finish is a distinct three-note ascending cadence A4 → F#5 → D6 (580 ms), with quiet lower D/A support blooming under the last note. The final tonic should feel like an arrival; never make finish merely the start cue reversed. Rounded attacks, restrained upper partials, a tiny room tail, and tapered endings prevent clicks and fatigue.
- Assets are 48 kHz stereo PCM WAV, with narrow stereo width and mono-compatible content. Peak level is -12 dBFS and runtime volume is 0.55; avoid normalizing notifications to music loudness. Honor system volume and audio output.
- Preload before interaction. Play start once after capture succeeds; play finish only after the microphone has stopped and the session was saved for transcription. Neither playback nor its tail may delay capture, upload, or animations.
- Never layer cues during rapid toggles: stop the previous cue before playing the next. Stop playback on quit, failed start, and discarded double-tap recordings. No additional success, cancellation, retry, error, or history sounds. Visual previews are silent.
- Start audio must be short and quiet because the microphone is already active; do not delay microphone capture or drop user speech to avoid speaker bleed.
- Missing or unavailable playback must fail silently and never break dictation. Keep the synthesis source so sound changes are reproducible.

## Stack and behavior

Swift is compiled with `swiftc`; SwiftUI renders the screens; AppKit owns the menu bar, windows, nonactivating panel, frame animations, and fades. AVFoundation preloads and plays the custom WAV earcons with AVAudioPlayer, records mono 24 kHz AAC `.m4a` and supplies microphone levels. Core Graphics listens for right Option and posts Command-V. Foundation URLSession uploads recordings. Darwin `flock` prevents multiple instances. There are no third-party dependencies, web frontend, Electron runtime, or database.

`Sources/main.swift` acquires `~/Library/Application Support/Voice/instance.lock` before running NSApplication. The lock releases on normal exit or crash. `Sources/Core.swift` contains configuration, history persistence, the transcription client, gesture logic, and the lock. `Sources/WorkQueue.swift` owns the main-actor ordered background work queue. Capture state is independent of its pending jobs. `Sources/Hotkey.swift` owns the event tap. `Sources/SoundCues.swift` preloads original start/finish sounds from bundle resources. `Scripts/design_sounds.py` deterministically synthesizes the two assets using only Python’s standard library; it is a development tool, not a runtime dependency. `Sources/App.swift` owns recording lifecycle, cancellation/paste, native windows, visual transitions, and SwiftUI views.

Right Option release starts or finishes recording immediately. A pending transcription never blocks or cancels the next recording; another press starts the next session. Left Option and Option+key/modifier chords do not trigger recording. Bare long presses still trigger on release. Double-tap within 300 ms opens history when the first tap just started a tentative recording; discard that tentative session without uploading or retaining it. A rapid finish/start pair is always two single actions, so starting the next recording immediately cannot be mistaken for opening history. Do not delay the first action to distinguish a double tap.

The current recorded-speech model is `gpt-transcribe`, used through `POST https://api.openai.com/v1/audio/transcriptions`. Read the key file directly on each request so Finder launch does not depend on a shell environment. Do not silently fall back to an older model. Model access and billing depend on the key's project. Audio is uploaded only on finish or retry.

Save sessions under `~/Projects/Voice/History/<id>/`: `audio.m4a`, `recording.json` (timestamp in Unix milliseconds, duration, model, text/error), and `transcript.txt` on success. Retain the latest 100 sessions including genuine failures/interrupted recordings. Delete older sessions as complete folders, but protect active recordings and pending transcription jobs until they finish; temporarily exceed the limit if needed, then prune after delivery. Directory permissions are 700; audio, text, and metadata are 600. Stop automatically after 20 minutes to stay below the API's 25 MB upload limit. Save before clipboard/paste. Check task cancellation after the network response so quitting requests cannot paste late. Process completed recordings in submission order, including awaiting clipboard/paste delivery before the next job. One failed request must not drop subsequent jobs. Deduplicate queued retries by recording ID. Clipboards must not be overwritten by another result before the prior paste has had time to consume them. Network and delivery waits must yield rather than block the main run loop.

Microphone, Accessibility, and Input Monitoring permissions are configured through native System Settings. Without Accessibility the result remains on the clipboard for manual paste. Paste targets the currently focused app using its normal Command-V behavior. Opening history intentionally activates its window; the recording panel never does. Menu bar actions provide History, Permissions, Recordings, and Quit.

## Build and verification

Run `./build.sh` and `./test.sh` after code changes. The build produces `build/Voice.app` and locally ad-hoc signs it with the stable identifier `local.l.voice`. Quit before rebuilding; reopen the updated bundle after checks. Launch with `open ~/Projects/Voice/build/Voice.app` or `Launch Voice.command`. Stop cleanly with `build/Voice.app/Contents/MacOS/Voice --quit`; SIGTERM also saves active audio and exits cleanly.

Tests cover immediate taps, rapid finish/start, double taps, chords, long presses, exclusive locking/release, latest-100 retention, persistence/permissions, and mocked API success/error handling. `Tests/Overlap/main.swift` injects delayed transcription and paste consumers to verify ordered delivery, overlap with active capture UI, failure continuation, retry deduplication, protected retention, and active/waiting cancellation on quit without touching the real microphone, key, clipboard, or API. For lifecycle changes, verify simultaneous direct launches, `open -n`, graceful quit, and restart. For UI changes, run `./preview.sh` to generate recording, transcribing, history, and permission screenshots in both appearances under `build/previews/`, and verify resize and completion hiding. This uses disposable sample data with no microphone or API request. Inspect the actual images before handing off; keep preview data out of real history.

An explicit API smoke test may use `build/Voice.app/Contents/MacOS/Voice --transcribe-file /path/to/audio.m4a`. It uploads that file and prints the transcript only, without modifying history or pasting. Never print the API key when testing.

## Login startup

Voice starts automatically when this Mac account logs in. The per-user LaunchAgent at `~/Library/LaunchAgents/local.l.voice.login.plist` runs `/usr/bin/open -g ~/Projects/Voice/build/Voice.app` with `RunAtLoad=true` in the Aqua session. The plist contains an absolute expanded app path; shell tilde expansion is not used by launchd. LaunchServices opens the signed app bundle so microphone and other app permissions remain associated with Voice. Existing single-instance locking still applies.

There is no KeepAlive policy: quitting Voice leaves it closed for the rest of the session. Startup is at user login, after a reboot or logout, rather than before a user signs in. Keep the app at the configured path, or update the LaunchAgent if moving it. Rebuilds replace the same bundle and need no startup re-registration.

To disable login startup, run `launchctl bootout gui/$(id -u)/local.l.voice.login` and remove only `~/Library/LaunchAgents/local.l.voice.login.plist`. Do not modify other login agents. This login configuration contains no API key; Voice continues loading the key directly from its separate secret file.

## Public repository

The public repository is `https://github.com/lukejagg/voice`, licensed under MIT. Use the GitHub noreply commit identity rather than a personal email. Stage source, tests, synthesis assets, scripts, public documentation, and curated sample-data images explicitly. Never stage real History, generated builds, API credentials, local account configuration, auth files, crash reports, or raw desktop screenshots. Public UI images come only from `Tests/Visual/main.swift` with invented data. The single README banner is generated brand artwork, not a product screenshot. A background transcription no longer keeps a progress HUD open, so do not present the diagnostic transcribing preview as a normal workflow screenshot.

Keep the public overview in this order: brief purpose and motivation, how it works, design principles with only recording-flow visuals, product principles, setup, and technical details. Use direct section names, compact anchor navigation, and no metadata badge row. Avoid repeating history screenshots or opening with implementation details. The animation must show the panel disappearing during background transcription and returning for a new recording; captions outside the panel are explanatory presentation, not additional app UI. Clearly disclose simulated levels/timing.

To regenerate the README animation, run `./preview.sh`, then `build/VoicePreview build/previews --motion`, then `python3 Scripts/render_motion.py`. The encoder requires Pillow only for development. Native rendering never records audio or calls the API; frames remain under ignored `build/previews/motion/`. The published GIF loops through starting, recording, background processing, and another recording. Keep a still-frame fallback next to it.

The banner at `docs/images/banner.jpg` was generated with the built-in image generation tool and encoded as JPEG without source metadata. Its art direction is an ivory background, precise charcoal wordmark, and a translucent glass sound wave settling into a quiet line.

Banner generation prompt:

> Use case: ads-marketing. Asset type: one wide GitHub repository banner for Voice, an exquisitely minimal macOS dictation app. Create a finished editorial brand image, wide landscape 3:1 composition. Warm ivory paper background, generous negative space, extraordinary typographic precision. On the left, exact single word "Voice" in large elegant charcoal contemporary sans-serif typography, beautifully kerned. On the right, a single abstract sculptural sound wave formed from a flowing, folded translucent smoked-glass ribbon, gently resolving from loose ripples into a calm line; subtle soft shadow, refined studio light. Understated monochrome palette: ivory, charcoal, silver, with the faintest warm light. Art direction: quiet, premium, expressive, tactile, considered. Only text is "Voice". No interface mockups, no badges, no buttons, no device frame, no logos other than the word, no feature lists, no extra words, no watermark. This must feel like a beautifully designed independent native product, not a generic tech illustration.

Before committing or publishing, run `python3 Scripts/audit_public.py` on the index and review all staged paths. It compares against the optional local key without printing it, checks known credential formats and machine-specific home paths, and blocks private/generated files. This is defense in depth, not a guarantee that arbitrary new prose contains no personal information. Review screenshots and metadata manually too.

`Scripts/login_startup.py enable|disable|status` manages only Voice's per-user login agent using the checkout's actual app path. It never reads secrets and does not affect other agents. CI builds, tests, and audits the public files without any API key or real microphone capture.

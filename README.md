# Voice2028

Voice2028 is a personal-use iPhone voice keyboard. When its background service is alive, it starts capture without leaving the current text field. If background activation fails, it briefly wakes its containing app, returns automatically, transcribes with ChatGPT, and inserts the result through the keyboard extension.

## Current interaction

The v0.4.10 handoff-priority flow follows the current Typeless iOS interaction observed in version 2.6.2:

1. Open a text field and switch to the Voice2028 keyboard.
2. Tap the central microphone.
3. If the microphone is still warm and ready, recording resumes without leaving the current app. If the microphone has gone cold, Voice2028 immediately opens in the foreground, activates the microphone and starts the recording request, then automatically returns to the original app.
4. Voice2028 keeps the v0.4.2-style mixable play-and-record audio session unchanged while the microphone is warm. Speak while the keyboard shows the recording state.
5. Tap the microphone again to finish. The keyboard shows processing and inserts the result automatically when it is ready; there is no insertion confirmation.

There is no floating overlay or video-based background mode. New recordings reuse the warm microphone when it is still ready; once it is cold, Voice2028 skips the failed background restart attempt and goes straight to foreground wake-and-return.

## Keyboard design

- Compact Voice2028 header
- Smart Cleanup / Verbatim mode switch
- Automatic spoken-language detection, including mixed Chinese and English
- Large central voice button with idle, recording, and processing states
- Globe, newline, and delete controls
- Voice-only design; no QWERTY or Pinyin keyboard is bundled

## Modes

- **Smart Cleanup (default)** adds punctuation and paragraphs, removes meaningless filler and repetition, and fixes obvious grammar or word-order problems. It must preserve meaning, names, numbers, amounts, dates, units, model numbers, and technical terms. It must not add information or summarize substantive content.
- **Verbatim** returns the transcription without a second-pass rewrite. It is intended for quotations, interviews, and meeting records.

Smart Cleanup first calls the transcription endpoint, then sends the raw transcript through `https://chatgpt.com/backend-api/codex/responses` with strict cleanup instructions. If cleanup fails, Voice2028 returns the valid raw transcript instead of losing it.

## Architecture

- **Voice2028 app** handles ChatGPT OAuth, microphone permission, recording, transcription, and smart cleanup.
- **Voice2028Keyboard extension** handles mode control, background-first recording requests, app recovery, service status, automatic result insertion, newline, delete, and keyboard switching.
- **Localhost bridge** connects the keyboard and containing app through `127.0.0.1:14557`, avoiding the App Group entitlement unavailable to free Apple developer accounts.
- **KeyboardKit host resolver** identifies the app that owns the active text field on current iOS releases so Voice2028 can return after foreground capture starts.

The containing app records on behalf of the keyboard because iOS keyboard extensions cannot access the microphone directly. Recordings have no fixed duration limit and are uploaded through a temporary multipart file instead of being copied fully into memory.

## Microphone lifecycle

- The microphone starts only after the user taps the Voice2028 voice button.
- Leaving the input interface starts a 10-second grace period.
- If the keyboard does not return during that period, capture stops. An active recording is finished and transcribed; an idle microphone is closed.
- The background service keeps only a silent audio session alive so the localhost bridge remains reachable. It resumes capture directly when iOS permits; otherwise the keyboard automatically falls back to foreground wake-and-return.

## Foreground handoff reliability

- Foreground wake-and-return now restores the v0.4.2 audio-session policy: one stable `.playAndRecord + mixWithOthers` session is configured before AVAudioEngine starts and is not changed when capture begins.
- The local keyboard bridge is rebuilt during foreground handoff with a fresh server ID so a stale long-running localhost listener cannot survive into the returned keyboard session.
- Voice2028 returns to the host app only after capture actually enters `recording`; a failed start is cleaned up instead of returning with a half-active microphone.
- If the returned keyboard never reconnects, an orphaned recording is abandoned after 5 seconds and the microphone is returned to silent standby automatically.

## Fast upload path

- Audio is converted to 16 kHz mono 16-bit PCM while it is being recorded, so stopping dictation no longer starts a second full-file conversion pass.
- Normal recordings up to 12 MB build multipart data directly in memory and begin upload immediately, avoiding a second multipart temp-file write/read cycle.
- Longer recordings automatically keep the disk-backed multipart path to bound memory use.
- If a particular audio route cannot create the 16 kHz converter, Voice2028 falls back to the native recording format instead of failing the recording.

## Faster transcription

- Recognition language is configurable as Chinese (default), Auto, or English. Chinese sends `language=zh`; English sends `language=en`; Auto omits the language hint.
- Voice2028 records the upload WAV as 16 kHz mono 16-bit PCM in real time when the active audio route supports conversion, removing the post-record conversion delay.
- The warm-microphone, silent-standby, smart-handoff, cleanup, and auto-insert behavior are otherwise unchanged. Automatic interruption of other-app audio is intentionally disabled in this reliability-first build.

## Build and sideload

The `Build` GitHub Actions workflow selects Xcode 26.3, validates a simulator build, archives an unsigned iPhone build, and uploads `Voice2028-unsigned.ipa`.

1. Push a commit to `main` or a `codex/**` test branch.
2. Download the `Voice2028-unsigned` artifact from the completed workflow.
3. Sideload the IPA with AltStore/AltServer using the same free Apple ID as previous Voice2028 builds.
4. A free Apple signature normally needs refreshing every 7 days.

## Limitations

The ChatGPT/Codex endpoints used by this project are undocumented and may change. Generic automatic return to another iOS app also has no supported public API, so the personal-sideload return helper must be verified on each iOS release. If automatic return is rejected, Voice2028 keeps recording and shows a clear message so the user can return manually.

## Status

v0.4.10 handoff-priority test: based on the stable v0.4.2-era code. While the microphone remains warm, a new recording starts without an app switch. Once the microphone is cold, Voice2028 immediately uses foreground wake-and-return instead of first attempting a background microphone restart. Silent-audio standby, warm microphone retention, automatic result insertion, smart cleanup, and spoken-language detection remain preserved.

## Acknowledgements

The design was informed by Typeless's public iOS behavior and the MIT-licensed `A3Boy/codex-voice-input` and `n0an/VivaDicta` projects. See `NOTICE.md` and `LICENSE`.

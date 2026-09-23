# Voice2028

Voice2028 is a personal-use iPhone voice keyboard. When its background service is alive, it starts capture without leaving the current text field. If background activation fails, it briefly wakes its containing app, returns automatically, transcribes with ChatGPT, and inserts the result through the keyboard extension.

## Current interaction

The v0.5.2 flow follows the current Typeless iOS interaction observed in version 2.6.2:

1. Open a text field and switch to the Voice2028 keyboard.
2. Tap the central microphone.
3. If Voice2028 is alive in the background, capture starts without an app switch. If background activation fails, Voice2028 briefly appears, starts capture in the foreground, and automatically returns to the original app.
4. Speak while the keyboard shows the recording state.
5. Tap the microphone again to finish. The keyboard shows processing and inserts the result automatically when it is ready; there is no insertion confirmation.

There is no floating overlay or video-based background mode. Background resume is attempted first; wake-and-return is an automatic recovery path only when the background service cannot start a valid capture.

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
- Tapping stop ends file writing immediately. While the Voice2028 keyboard remains visible, the microphone engine stays ready for the next dictation.
- Leaving the input interface starts a 10-second grace period.
- If the keyboard does not return during that period, capture stops. An active recording is finished and transcribed; an idle microphone is closed.
- Voice2028 does not play silent audio in the background. It resumes capture directly only while iOS still allows the app to respond; otherwise the keyboard automatically falls back to foreground wake-and-return.

## Build and sideload

The `Build` GitHub Actions workflow selects Xcode 26.3, validates a simulator build, archives an unsigned iPhone build, and uploads `Voice2028-unsigned.ipa`.

1. Push a commit to `main` or a `codex/**` test branch.
2. Download the `Voice2028-unsigned` artifact from the completed workflow.
3. Sideload the IPA with AltStore/AltServer using the same free Apple ID as previous Voice2028 builds.
4. A free Apple signature normally needs refreshing every 7 days.

## Limitations

The ChatGPT/Codex endpoints used by this project are undocumented and may change. Generic automatic return to another iOS app also has no supported public API, so the personal-sideload return helper must be verified on each iOS release. If automatic return is rejected, Voice2028 keeps recording and shows a clear message so the user can return manually.

## Status

v0.5.2: keeps the v0.5.1 bridge and microphone-safety fixes and clarifies the two microphone-off keyboard states as “service unavailable, tap to wake” and “service online, tap to speak.”

## Acknowledgements

The design was informed by Typeless's public iOS behavior and the MIT-licensed `A3Boy/codex-voice-input` and `n0an/VivaDicta` projects. See `NOTICE.md` and `LICENSE`.

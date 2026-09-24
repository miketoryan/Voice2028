# Typeless 2.6.2 clean-room audit

This document records observable package metadata and a review of Voice2028's
current behavior. It does not copy Typeless source code or infer proprietary
implementation details from product behavior.

## Reference artifact

- File: `Typeless 2.6.2.ipa`
- Size: 199,589,927 bytes
- SHA-256: `342BF8CE90F0DB997F0C2F3F2EF406A03D1F0B9C8BA3549B0AD3FDEBE533875C`
- Main bundle: `com.typeless.mobile`, version `2.6.2` (`3`)
- Keyboard bundle: `com.typeless.mobile.keyboard`
- Widget bundle: `com.typeless.mobile.dynamicisland`

The main app, keyboard extension, and widget Mach-O files all report
`cryptid = 1`. Their native executable regions are App Store encrypted, so
this audit does not claim access to their native implementation. A React
Native/Hermes bundle is present, but implementation code was deliberately not
used as a source for Voice2028. Only package metadata, entitlements, linked
framework names, and externally observable behavior are in scope.

## Observable Typeless capabilities

The main app declares:

- `UIBackgroundModes`: `audio`, `remote-notification`
- microphone permission text
- `NSSupportsLiveActivities` and frequent Live Activity updates
- the `typeless` URL scheme
- local networking permission
- an App Group: `group.com.typeless`
- a shared keychain access group
- production push notifications and associated domains

The keyboard extension:

- is an open-access custom keyboard (`RequestsOpenAccess = true`)
- shares the App Group and keychain group with the main app
- allows local networking
- links AVFoundation/AVFAudio, AudioToolbox, UIKit, Hermes, and networking
  frameworks

The second extension is a WidgetKit/ActivityKit extension and shares the App
Group. The package embeds `OpenSSL.framework`, `AdjustSigSdk.framework`, and
`hermes.framework`.

These declarations show the available system capabilities, not how Typeless
implements background readiness. In particular, an App Group can persist and
share state but cannot by itself wake a suspended app or grant microphone
access to a keyboard extension.

## Voice2028 current behavior

### Audio lifecycle

`AudioService.enterStandby()` already separates process readiness from input
capture: it stops `AVAudioEngine`, removes the input tap, keeps one
`.playAndRecord` / `.measurement` session active, and loops a silent WAV. This
is the closest existing mechanism to the desired long-lived ready state with
the input engine off.

There are two privacy/reliability mismatches:

1. `arm()` starts `AVAudioEngine` and installs its input tap before
   `beginCapture()` creates the recording file. `microphoneReady` therefore
   means the input engine is running, not that a recording file is active.
2. `endCapture()` clears the file but leaves the input engine running. The
   keyboard's stop command calls `beginFinishingRecording(...,
   deactivateMicrophoneAfterCapture: false)`, so the input can remain active
   during transcription and until the keyboard heartbeat has been absent for
   ten seconds.

The second point directly conflicts with the requested rule that the
microphone indicator should be active only during capture.

### Keyboard start path

The bridge already supports an asynchronous background start with a timed
foreground fallback. `startRecordingRequest(allowForegroundFallback: true)`
can send `.startRecording`, wait for the live app to arm audio, and open the
containing app only if that attempt fails.

The normal microphone-button path does not use it. When `serviceReady` is true
but `microphoneReady` is false (the expected silent-standby state),
`toggleRecording()` immediately calls `launchVoice2028AndResumeRecording()`.
That guarantees an app switch instead of first testing whether the live
background service can start capture.

### Bridge and stale state

- The keyboard polls a live loopback server and sends a heartbeat every two
  seconds while visible.
- The server publishes a per-process `serverID` and monotonic revision.
- The listener retries after failures and is rebuilt during foreground
  handoff.
- A missing keyboard heartbeat finishes an active recording or returns idle
  audio to standby after ten seconds.
- A foreground handoff that never reconnects abandons capture after five
  seconds.

Because `serviceReady` is obtained from a live HTTP response, it is not merely
a persisted stale flag. However, the app does not observe audio interruptions,
route changes, or media-services resets, so `serviceReady` can remain true
while the silent standby player is no longer keeping the process ready.

### Public API boundary

The primary handoff uses SwiftUI `openURL`. Two fallbacks are not public API:

- the keyboard walks the responder chain using the private `openURL:` selector
- the main app uses `LSApplicationWorkspace` selectors to reopen the previous
  host application

No new design should depend on those private selectors. Generic automatic
return to an arbitrary host app has no public iOS API, so the supported result
must be best-effort and degrade to a clear manual-return path.

## Candidate direction for the next implementation plan

The smallest evidence-backed change set is:

1. Keep silent-output standby as the long-lived ready state.
2. From the keyboard, try the live bridge's background start before opening
   Voice2028, with the existing timeout/error fallback.
3. Stop the input engine and return to silent standby immediately when capture
   ends, before transcription begins.
4. Recover silent standby after audio interruptions and media-service resets;
   publish an honest unavailable state when recovery fails.
5. Preserve the current request IDs, auto-insertion, transcription modes,
   OAuth, and foreground recovery path.

Device validation remains necessary because iOS decides whether a background
audio process may activate input after long idle. The implementation must not
claim that metadata alone proves Typeless behavior or that iOS will permit
every background start.


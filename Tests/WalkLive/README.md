# Live Walk voice session

NanoVoice's home has two rows: Dam Rass and Eating, Moving, Alivening. Exact normalized titles resolve against synced peers, then IDs are cached per account. Cached IDs are validated without changing valid renamed chats. Unresolved/ambiguous names open an explicit bot/group selector; the info button can rebind either slot. Duplicate bindings are rejected. This is a focused home, not a security boundary against manually followed Telegram links. In-app banners are filtered to those IDs.

Start Walk mode in one native chat while the phone is unlocked. On iOS 17+, microphone permission starts a managed `.voiceCall` audio session and a voice-processing AVAudioEngine input tap. Input starts muted. The active account is included in SharedWakeupManager's background-audio tasks, keeping Telegram's service/worker connections eligible while the input session runs. End Walk mode or navigate away from the chat to release it. Temporary sheets (including diagnostics and recovery) do not stop the session. There is no silent playback loop.

On supported AirPods, Apple's input-mute notification maps unmute to recording and mute to finish-and-send. The Walk menu has equivalent Record voice reply / Send voice reply actions. Only explicitly recorded segments enter the Opus encoder. Muted input is neither retained nor sent. Input is converted to 48 kHz mono Int16, matching TGOggOpusWriter's encoder rate, in 960-sample packets. Less than 0.5 seconds is discarded; there is no automatic duration cutoff or timed send. Explicitly finishing enqueues a native audio/ogg voice message to the selected peer. Interruptions, route loss, and ending the session save recoverable input as a protected local draft, scoped to account and peer. Recover recordings offers explicit send/discard; corrupt files are retained without hiding valid recordings. Already-authorized local notifications provide best-effort background feedback. Abrupt process termination still loses an active in-memory recording. If disk persistence fails, the emergency copy survives chat closure but not process termination; keep NanoVoice open and retry recovery.

Incoming AccountStateManager messages bypass notification mute filtering. WalkReplyGate accepts only new incoming audio from the selected peer, at/after session start, with deduplication; delayed delivery is accepted. MediaBox downloads in FIFO order (60-second timeout per attempt). Failed downloads or decoder stalls (30 seconds without progress, suspended while recording) retain their item and retry after 5 and 15 seconds, then expose manual retry. Other replies can proceed while a failed item waits, so retries can play out of original order. Retained reply queue entries last for the chat controller lifetime; the original messages remain in Telegram. The native MediaPlayer decoder renders through the already-owned voice session, using an optional external audio-session control. Recording waits for logical player-pause acknowledgement; sending resumes an interrupted reply five seconds earlier, clamped to zero. Hardware output-drain timing still requires device verification. There is no grace period between successive recordings. Audio arriving during recording queues until recording ends. Automatic playback uses the session player rather than the global voice playlist. Voice-processing other-audio ducking is explicitly minimized with advanced ducking disabled. This is a mitigation to test for the quiet-reply incident, not a confirmed diagnosis; `WalkVoiceSession.minimizeReplyDucking` allows a controlled default/minimum comparison before starting a session.

User validation on 2026-09-27 (build 17, iPhone 14 Pro): the owner confirmed the full AirPods record/send and locked-screen incoming playback loop. This is user-reported hardware validation, separate from automated tests.

## Checks

From the repository root:

```sh
python3 tools/nanovoice/test-walk.py
```

The capture test compiles the actual capture class and Telegram Opus writer on macOS (Homebrew opus/ogg and ffprobe required). It checks duration preservation for 16/24/44.1/48 kHz mono/stereo inputs, valid Ogg output, an actual 302-second recording, conversion-failure prefix recovery, repeated finalization, and explicit discard. The runner also tests delivery/progress/rewind policy, draft persistence/corruption isolation/in-flight sends, and bounded persistent diagnostics; it typechecks the Foundation helpers for the iPhone deployment target. Temporary Swift caches are deleted by the test runner; no Bazel cache is created. It sends nothing.

## Device checks

`--walk-demo --walk-chat-self-test` starts an isolated offline session and queues two local voice replies after microphone authorization. `--walk-demo --walk-lock-self-test` waits 90 seconds before queuing two replies: lock the phone during the wait. Fixture mode never sends captured audio to Telegram. Normal launch uses the real account.

Then test on the real account: start Walk mode, press AirPod to record, press again to send, lock, wait for a bot reply, and reply again without unlocking. Verify routing to the intended chat, intelligible recording, FIFO playback, interruption/disconnect cleanup, and End Walk mode.

Diagnostics: Documents/nanovoice-chats.txt contains only resolution status for the two titles. Walk → Share diagnostics exports the shared log in Documents/WalkDiagnostics, retained across chats/launches. Three 512 KiB segments plus one bounded export include session IDs, timestamps, route port types, volume, category/mode/options, engine/mute/ducking and player states. No device names, message text, audio or credentials are logged. Logs are excluded from backup. Old walk-chat-events.txt files are no longer updated.

## Reliability device acceptance

- Record longer than five minutes: no timed stop or send; explicitly send and check the full duration.
- Interrupt a reply after 20 seconds, record, then send: resume near 15 seconds. Repeat near the beginning and with rapid record/cancel. Replies arriving during recording must wait.
- Repeat with screen locked and AirPods; compare volume before/after idle and against ordinary playback. Export diagnostics if volume differs.
- Interrupt a long recording with a call or route loss: no auto-send; recover the draft in the same account/chat after relaunch. Verify temporary sheets do not stop Walk.
- Delay network delivery beyond 90 seconds; simulate a download timeout and malformed audio: subsequent replies must proceed and failed items remain retryable.
- Rebind a slot, cancel selection, rename its bound chat, and exercise ambiguous/missing titles. The normal home must still show only two rows.

These are hardware acceptance checks, not claims that they have passed on the new build.

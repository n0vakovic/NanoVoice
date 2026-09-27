# Live Walk voice session

NanoVoice's home has two rows: Dam Rass and Eating, Moving, Alivening. Exact normalized titles resolve against synced peers, then IDs are cached per account. Unresolved/ambiguous names fail closed. This is a focused home, not a security boundary against manually followed Telegram links. In-app banners are filtered to those IDs.

Start Walk mode in one native chat while the phone is unlocked. On iOS 17+, microphone permission starts a managed `.voiceCall` audio session and a voice-processing AVAudioEngine input tap. Input starts muted. The active account is included in SharedWakeupManager's background-audio tasks, keeping Telegram's service/worker connections eligible while the input session runs. End Walk mode or leave the chat to release it. There is no silent playback loop.

On supported AirPods, Apple's input-mute notification maps unmute to recording and mute to finish-and-send. The Walk menu has equivalent Record voice reply / Send voice reply actions. Only explicitly recorded segments enter the Opus encoder. Muted input is neither retained nor sent. Input is converted to 48 kHz mono Int16, matching TGOggOpusWriter's encoder rate, in 960-sample packets. Less than 0.5 seconds is discarded; recording is limited to five minutes. Finishing enqueues a native audio/ogg voice message to the selected peer. Interruptions, route loss, and ending the session discard unfinished input.

Incoming AccountStateManager messages bypass notification mute filtering. WalkReplyGate accepts only new incoming audio from the selected peer, at/after session start and no more than 90 seconds old, with deduplication. MediaBox downloads in FIFO order (60-second timeout). The native MediaPlayer decoder renders through the already-owned voice session, using an optional external audio-session control. Recording pauses playback; sending resumes it. Audio arriving during recording queues until recording ends. Automatic playback uses the session player rather than the global voice playlist.

User validation on 2026-09-27 (build 17, iPhone 14 Pro): the owner confirmed the full AirPods record/send and locked-screen incoming playback loop. This is user-reported hardware validation, separate from automated tests.

## Checks

From the repository root:

```sh
swiftc -module-cache-path /Users/milan/coding/_third_party/telegram-build/swift-test-cache \
  submodules/TelegramUI/Sources/WalkReplyGate.swift Tests/WalkLive/main.swift \
  -o /Users/milan/coding/_third_party/telegram-build/walk-live-gate-tests
/Users/milan/coding/_third_party/telegram-build/walk-live-gate-tests
python3 Tests/WalkLive/test_capture.py
```

The capture test compiles the actual capture class and Telegram Opus writer on macOS (Homebrew opus/ogg and ffprobe required). It checks duration preservation for 16/24/44.1/48 kHz mono/stereo inputs, valid Ogg output, repeated finalization, and draft discard. It sends nothing.

## Device checks

`--walk-demo --walk-chat-self-test` starts an isolated offline session and queues two local voice replies after microphone authorization. `--walk-demo --walk-lock-self-test` waits 90 seconds before queuing two replies: lock the phone during the wait. Fixture mode never sends captured audio to Telegram. Normal launch uses the real account.

Then test on the real account: start Walk mode, press AirPod to record, press again to send, lock, wait for a bot reply, and reply again without unlocking. Verify routing to the intended chat, intelligible recording, FIFO playback, interruption/disconnect cleanup, and End Walk mode.

Diagnostics: Documents/nanovoice-chats.txt contains only resolution status for the two titles. Documents/walk-chat-events.txt contains timestamps and audio/session states, not message text or captured audio.

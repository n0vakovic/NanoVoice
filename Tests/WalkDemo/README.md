# Walk mode in the regular Telegram chat

Launch the simulator build with `--walk-demo`. It uses Telegram's regular AppDelegate, an isolated local account database, the actual ChatController, Postbox messages, and the shared MediaManager voice player. The synthetic account cannot make Telegram network requests. No API credentials or login are needed.

```sh
xcrun simctl launch --terminate-running-process booted local.milan.NanoVoice --walk-demo
```

The app opens Russ's chat. Tap **Russ · Walk Off** (or Emma) to start a session or inject one/two local voice replies. Incoming fixtures become ordinary voice-message bubbles. When Walk mode is on they enter a FIFO queue. End Walk mode or leaving the chat stops playback and clears the queue. Replies received while off are visible but are not queued for later autoplay. Emma is also available in the chat list.

For the native playback smoke check, add `--walk-chat-self-test`. This turns Walk mode on and inserts two replies after the chat appears. The native fixture audio is Opus/Ogg, converted from the synthetic speech samples below. The app writes insertion and native player events to `Documents/walk-chat-events.txt`.

Verified in simulator on 2026-09-25 (build 10): both replies entered the playing state, advanced to approximately 5.95 seconds, and ended sequentially. Normal launch still opens Telegram onboarding. Evidence is in `../telegram-build/walk-native-chat-events.txt` and `walk-native-chat.png`.

This launch mode is an offline integration prototype. The normal launch now includes a live incoming-message subscription and download queue; see ../WalkLive/README.md. Hands-free recording and reliable delayed background reception remain future work. The old coordinator tests below cover only the earlier standalone prototype, not the new native integration.

---

# Earlier standalone audio prototype

This demo ships inside the Telegram app but uses a separate launch-argument-selected app delegate. Normal launches still use Telegram's original delegate. No account, Telegram API key, bot, or server is contacted by the demo.

## Try it

After building and installing the simulator app:

```sh
xcrun simctl launch --terminate-running-process booted local.milan.NanoVoice --walk-demo-panel
```

Select Russ or Emma, start Walk mode, and receive a reply. Two replies queue in order. Pause holds the current reply and the queue; resume continues. End clears the queue immediately. Changing agents ends the session. Messages injected while off and history messages never replay when enabling a session.

The two bundled AIFF fixtures are generated using macOS Samantha speech synthesis. They are synthetic demo speech, not recordings of the user or agents.

## Tests

Run the transport-independent coordinator checks from the repository root:

```sh
swiftc -module-cache-path ../telegram-build/swift-test-cache \
  Telegram/Telegram-iOS/WalkDemo/WalkAudioCoordinator.swift \
  Tests/WalkDemo/main.swift -o ../telegram-build/walk-coordinator-tests
../telegram-build/walk-coordinator-tests
```

Exercise real AVAudioPlayer playback, FIFO completion, and pause/resume in the simulator:

```sh
xcrun simctl launch --terminate-running-process booted local.milan.NanoVoice \
  --walk-demo-panel --walk-demo-self-test
```

After 30 seconds, the app's Documents/walk-demo-events.txt records PASS or FAIL. This test uses real decoded audio and player completion callbacks. Simulator playback success does not verify audibility through physical AirPods.

## Integration boundary

`WalkAudioCoordinator.receive(_:isNew:)` accepts a downloaded audio file, stable message ID, and stable chat ID. A future Telegram adapter must feed only incoming audio from the selected peer, preserve chat-scoped IDs, identify history versus new delivery, download files before enqueueing, and deliver events on the main thread. The demo does not yet connect to Telegram's message store or MediaManager. Its AVAudioSession ownership is isolated from Telegram's normal delegate; real integration must coordinate with Telegram's existing audio manager.

Audio interruptions and removal of the current output device pause playback and require explicit resume. Microphone recording, voice activity detection, remote lock-screen controls, Telegram delivery in the background, and physical-device/AirPods validation are out of scope for this prototype.

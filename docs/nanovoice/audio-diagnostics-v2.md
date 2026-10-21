# Audio diagnostics v2

Purpose: investigate quiet Walk replies, especially after restarting Walk, with passive instrumentation. The subsequent owner-approved playback change is
described below; routing, ducking, and session activation behavior remain unchanged.

Independent review found an important confounder: ordinary voice playback passes
isAudioVideoMessage=true; Walk previously left it false. Telegram's renderer can
apply +12 dB EQ to voice messages (+5 dB on some subsequent route overrides).
This may explain a baseline difference, but not by itself sudden quietness after
restart. Voice-processing attenuation and session reconfiguration remain hypotheses.

Tracing starts with Walk and continues for 600 seconds after its last active voice
session ends. Starting Walk again renews it. It is passive: no audio lease, microphone
capture, or background assertion is added. Suspension may delay callbacks; the
lower-level gate uses monotonic uptime to reject events after expiry regardless.
The window is process-local and does not resume after force quitting the app.

Capture:
- Session category/mode/options, route port types (including previous output),
  system volume old/new, sample rate, channel counts, IO buffer duration/latencies,
  other-audio flags, interruption/reset notifications, and lifecycle checkpoints.
- Both Walk and ordinary MediaPlayer renderers: actual mixer input gain and EQ
  global gain with read OSStatus, requested gain, voice-message flag, mute/speaker
  flags, output-unit choice, graph running state, playback rate, start/close events.
- Sparse decoded signed16 PCM RMS/peak (at most 4096 samples every two seconds),
  computed on the renderer worker queue, never in its realtime callback. These
  are pre-mixer levels, not acoustic loudness or a whole-file loudness measurement.
- Random player/renderer IDs and a per-process opaque media token. Compare the same
  media token and sampleIndex for meaningful source-level comparisons. Tokens do
  not correlate across app relaunches. No raw media/chat IDs, paths, names, text,
  credentials, or audio samples enter the diagnostic log.

The existing protected rotating store (3 x 512KiB) bounds retained diagnostics.
The bridge is enabled only by the NanoVoice-specific Walk monitor; official Telegram
builds remain inert. Its sink is protected by a lock and called outside that lock.

When quiet: optionally use Walk > Mark audio too quiet; stop Walk, replay the same
message normally at its starting volume and then at maximum; export via Share
diagnostics within ten minutes. The logs capture the state and gain comparison,
but subjective loudness still requires the listener's observation. The marker is
recorded even if the tracing window has expired, with that state made explicit.

Checks: focused gate-expiry/restart/reentrancy and signed PCM level tests, existing
Walk regression suite, independent read-only source review, and full iPhone build.
After reviewing this finding, Milan explicitly requested the same voice-message
boost. Walk now passes isAudioVideoMessage: file.isVoice, matching ordinary
Telegram voice classification. This delegates EQ treatment to the upstream renderer
rather than hardcoding another gain; music/audio files keep their normal treatment.
It addresses the concrete configuration mismatch, not a proven restart/ducking bug.
Rollback source tag:
`nanovoice-before-audio-diagnostics-20261021`.

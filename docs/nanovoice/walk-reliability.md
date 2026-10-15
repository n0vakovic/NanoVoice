# Walk reliability changes — 2026-10-15

## Scope and commits

The rollback point is tag `nanovoice-before-walk-reliability-20261015`
(`ad1a1264`). It includes the documentation edits that were present before this work.

- `1bf5aaa9`: validate and explicitly rebind the two agent chats.
- `aa854bd5`: recording recovery, playback rewind/retry, volume mitigation, diagnostics.
- `59480856`: focused test runner and updated device acceptance instructions.
- `7ee637b0`: ordinary explicit sends survive chat teardown; enqueue failures retain a recoverable draft.

The implementation received independent reviews of recording lifecycle, playback
recovery, draft persistence and duplicate sends, chat binding, and diagnostic I/O.
Review findings were addressed before these commits.

## Behavior

- No five-minute stop or timed send. Muting/sending remains an explicit action.
- Ordinary interruptions and session teardown save a recoverable recording to the
  original account/chat. Recovery requires explicit send or discard. Local
  notifications are attempted only if notification permission already exists.
- Replies wait during recording. Interrupting a reply resumes it five seconds
  earlier, clamped to zero. The player acknowledges pause before capture begins.
  Between separate recordings playback may immediately resume.
- Replies delayed more than 90 seconds remain eligible if created during the
  current Walk session. Failed downloads and decoder stalls do not wedge the queue;
  automatic retries are bounded, then the Walk menu offers manual retry.
- Minimum other-audio ducking is a mitigation for quiet playback, not confirmation
  of the root cause. Route/volume/session diagnostics support further investigation.
- Agent slots validate saved identities and offer explicit selection/rebinding.
  Renaming a valid chat does not change its identity. Home still has two rows.
- Walk → Share diagnostics exports bounded logs retained across chat screens and
  launches. Logs contain state, not conversations, audio, credentials or device names.

## Verification and limits

Run `python3 tools/nanovoice/test-walk.py` from the repository root. The focused
checks passed, including a real 302-second capture, failure-prefix recovery, delayed
delivery and progress policy, persistent/corrupt drafts, duplicate-send guards,
log rotation and failed I/O, and iPhone SDK typechecking of the Foundation helpers.
This runner creates temporary Swift caches, not a Bazel cache.

Complete app compilation is tracked at
https://github.com/n0vakovic/NanoVoice/actions/runs/38748668351 for source `7ee637b0`.
The earlier run was cancelled during preparation to include the send-lifetime fix.
At the time this note was written it was running; do not infer success from this
link. This is the public unsigned workflow using dummy credentials, not the private
signed workflow or WarpBuild. An unsigned artifact cannot be installed as-is.

Hardware acceptance is listed in `Tests/WalkLive/README.md`. In particular, the
new volume behavior, pause/output timing, locked-screen interruptions, and new UI
have not yet been confirmed on the iPhone. A logical pause acknowledgement does
not measure when AirPods physically stop emitting sound.

Active capture remains in memory until finish or orderly interruption. A process
kill can lose it. A failed disk save retains an emergency copy only for the process
lifetime. Background notifications are best effort and depend on iOS settings.
Reply retry entries live with the chat controller; their original Telegram messages
remain available even if that controller is destroyed.

## Reversal

To reverse the implementation and its test runner while retaining history and these notes:

```sh
git revert 7ee637b0
git revert 59480856
git revert aa854bd5
git revert 1bf5aaa9
```

Those commands create new commits; they do not rewrite upstream or delete local
data. Run from a clean checkout and resolve any future overlapping edits rather
than forcing a reset. These commands also return the focused test instructions to their previous state.
For an exact source checkout of the previous state, use the rollback tag in a
separate checkout. Reverting source does not downgrade an already installed app;
that needs a signed build or the retained previous signed app. Do not uninstall the
app to roll back: that can delete its locally saved drafts.

A read-only reverse-patch check against the rollback tag passed, and the working
tree was clean after committing the implementation.

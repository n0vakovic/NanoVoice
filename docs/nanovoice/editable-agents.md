# Editable My Agents (2026-10-20)

My Agents now stores an ordered, account-specific list of bot/group conversations.
The Add button opens Telegram's searchable local conversation picker, followed by an
optional NanoVoice-only name and Add confirmation. Edit enables drag reordering,
renaming (blank uses Telegram's current name), and removal. Removal never deletes
Telegram messages or leaves a group. An empty list stays empty after restart.

Rows use Telegram's AvatarNode (current photo or initials) and message-description
formatter. Postbox peer/history subscriptions update names, photos and previews
without changing order; visual refreshes are deferred during editing so an incoming
message cannot interrupt a reorder gesture. Unavailable saved chats retain their
identity until the user explicitly picks a replacement.

The previous Rass/EMA peer bindings migrate once into versioned local preferences.
Their old preference keys remain unchanged for rollback. Selection rejects duplicate
peers, personal/secret chats, and groups the account cannot write to. All selected
agents get the existing Walk controls. The active Walk owner is tracked weakly;
removing it explicitly ends its session. Reordering/renaming never retargets Walk.
Settings are local to this installation, not synchronized to Telegram.

## Validation and rollback

Focused tests cover migration, stable identities, ordering/names, account isolation,
an intentionally empty list, and preservation of legacy rollback keys. Run them with
`python3 tools/nanovoice/test-walk.py` (also runs existing Walk regression checks).
Full signed build and physical-device UI verification are recorded separately.

Pre-change tag: `nanovoice-before-editable-agents-20261020` (53a664e8fa).
The validated build 1011 app remains in `../telegram-build/signed-1011` until owner
acceptance of the new build. Reinstalling that app restores the two-slot experience;
its original bindings are untouched. Never uninstall the app to roll back.

After install, try: add the new group, give it a name, reorder, reopen the app,
rename, and remove/re-add. Check avatars/previews and the existing Walk loop.
Do not remove build caches or the rollback app before Milan confirms acceptance.

Build 1012 completed successfully on 2026-10-20: all 7,591 actions in 997 seconds.
The focused agents and Walk regression checks passed. Strict deep codesign
verification passed outside the sandbox; the embedded profile matches the phone.
Verified arm64, display name NanoVoice, bundle `local.milan.NanoVoice`, version
13.0 (1012). IPA SHA256:
`301f1eb94f4897bac295307d1fa8b3c548b81cf1098e530ee87cb6008686f7bb`.
The first install attempt was rejected by CoreDevice (4016, connection assertions
unavailable). After reconnecting, build 1012 installed successfully in place.
Startup verification is pending phone unlock (iOS denied launch because the device
was locked); owner acceptance and cleanup remain pending.


Build 1012 crashed on startup: the new preview requested count 1 from Postbox,
which computes halfLimit = count + 1 and requires halfLimit >= 3. The crash stack
points directly to HistoryViewLoadedState's precondition. Fixed in e4172b29f1 by
using the existing upstream convention of count 10, displaying only the newest
entry. A call-site regression check now guards the minimum request count.
Build 1013 compiled, signed, installed, and displayed the populated home screen.
Screenshot inspection then found Telegram's custom navigation bar does not render
the system Add item. Build 1014 uses an explicit Add text item instead.

Build 1014 compiled successfully, passed strict deep signature verification, and
installed in place. IPA SHA256:
`b736192e292f73e88761825d813d43cb6173b39a01203d5fcb6a648b1f50f3f1`.
The phone locked again before final launch verification; awaiting unlock.

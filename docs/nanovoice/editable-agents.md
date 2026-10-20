# Editable My Agents (2026-10-20)

My Agents now stores an ordered, account-specific list of bot/group conversations.
The + button opens Telegram's searchable local conversation picker, followed by an
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

# NanoVoice

Personal Telegram iPhone client focused on two agent conversations and hands-free Walk mode. This is an independent fork, not an official Telegram app. Upstream source and license notices are preserved.

## Verified working milestone

Build 17: the owner confirmed the full loop on iPhone 14 Pro with AirPods on 2026-09-27: headset press records, the next press sends to the selected agent, and incoming replies play while the phone is locked in Walk mode. This is user-reported hardware validation, not an automated test claim. Local tests also cover incoming-message filtering and Opus capture duration across microphone sample rates.

The app is named NanoVoice with a purple/pink icon. The two conversation titles are currently personal defaults in `NanoVoiceHomeController.swift`; customize them for another account. Walk mode explicitly keeps a muted communication session active. Unmute records, mute sends; ending Walk mode discards unfinished input and releases the microphone. See `Tests/WalkLive/README.md` for implementation details and test commands.

## Rebuilding on Apple Silicon

The source is synchronized to official Telegram `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838` (2026-10-07, app 13.0). Follow upstream `versions.json`: Xcode 26.6 and Bazel 9.2.0. The older working device build used Xcode 26.6 / iOS SDK 26.5 and Bazel 8.4.2; that does not establish validation of this updated base. Install Git LFS before checking out dependencies, and Xcode's Metal toolchain if requested. Clone recursively:

```sh
git clone --recurse-submodules https://github.com/n0vakovic/NanoVoice.git
cd NanoVoice
git remote add upstream https://github.com/TelegramMessenger/Telegram-iOS.git
```

Copy `docs/nanovoice/configuration.example.json` to an ignored location under `build-input/`, and fill in your own Telegram API credentials and Apple team. Keep the configuration private. Use your own bundle ID and matching provisioning profile with the `group.<bundle-id>` app group and development APNs entitlement; register your phone and install the matching Apple Development certificate/private key in Keychain. The current personalized UI is enabled for `local.milan.NanoVoice`; changing the bundle ID also requires updating that check in `NanoVoiceHomeController.swift`.

```sh
python3 tools/nanovoice/prepare-build.py \
  --configuration build-input/device-configuration.json \
  --profile /private/path/Telegram.mobileprovision
SIGNING_IDENTITY='Apple Development: YOUR CERTIFICATE NAME' \
BUILD_NUMBER=18 bash tools/nanovoice/build-device.sh
```

The setup helper downloads/checks the pinned Bazel binary and generates ignored build inputs. It has been syntax-checked; a clean rebuild with this new helper has not yet been run. The underlying Bazel command produced the working build. Extensions and Watch app are excluded.

Output: `bazel-bin/Telegram/Telegram_archive-root/Payload/Telegram.app`. Copy this outside Bazel's cache before retaining or re-signing it. Verify with `codesign --verify --deep --strict`, install with `xcrun devicectl device install app --device YOUR_DEVICE /path/to/NanoVoice.app`, then launch `local.milan.NanoVoice`. Use no demo arguments for the real account.

Credentials and signing files must never be committed. The inherited CI workflow is manual-only and uses upstream fake signing: it is not a configured NanoVoice delivery pipeline. The separate NanoVoice unsigned compilation trial is described below; signed cloud delivery is not yet configured.

## Upstream updates and cleanup

`origin` is the personal public repository; `upstream` is TelegramMessenger/Telegram-iOS. Fetch upstream and review/merge changes on a separate branch. The `nanovoice-v0.1.0` tag preserves the working milestone. Keep the upstream GPL license and attribution.

The 2026-10-16 sync preserves Walk mode, recording/reply reliability fixes, diagnostics, agent-chat binding, and NanoVoice branding. Our temporary Xcode 27 warning overrides, keyboard workaround, and scene delegate have been reverted; lifecycle, keyboard lookup, rotation, and SDK compatibility now come from upstream. `nanovoice-before-upstream-sync-20261016` preserves the exact pre-sync source, including the uninstalled build 1010 keyboard workaround. Builds 1008 and 1009 crashed on launch and are not working rollback builds; retain the known-working build 17 app. Focused Walk tests pass after the merge; full build and hardware validation are separate checks.

Build 1011 from merge commit `1f4d9ec3e7` completed all 7,591 actions on Xcode 27.0 with upstream's compiler settings and Bazel 9.2.0 (no local compatibility overrides). Focused Walk tests, including 302-second Opus capture, passed. The arm64 app passed strict/deep signature, bundle identity, scene manifest, and device-profile checks, was installed in place, and its running process and two-agent home screen were verified on the iPhone 14 Pro. IPA SHA-256: `4640e1ad3cae62222c3a327029db41da258cccb9b646a086cb69ab83aab9b18a`. The owner reported the update works on 2026-10-16 and authorized cleanup. Both Bazel caches and obsolete build artifacts were then removed. The validated build 1011 app, private configuration, standalone provisioning profile, signing project/entitlements, and latest build/test logs remain outside the repository. Individual device scenarios were not separately reported. The next build starts cold.

Bazel's output root is disposable and was approximately 25 GB. Preserve a signed app backup, private configuration/profile, and the signing key before deleting caches. Deleting these caches does not uninstall the app from the phone; the next build will be cold. Source and tests occupy less than 1 GB and are worth retaining.

## GitHub Actions compilation trial

The manual **NanoVoice unsigned iPhone build** workflow (`nanovoice-unsigned.yml`) uses a standard `macos-26` runner and Xcode 26.6. Trigger with:

```sh
gh workflow run nanovoice-unsigned.yml --repo n0vakovic/NanoVoice --ref nanovoice
```

This trial uses dummy API credentials and no personal signing keys. Bazel's device rule requires a profile input even with signing disabled, so `prepare-build.py --unsigned` copies the upstream checked-in test profile. `--define=nanovoice_unsigned=true` skips entitlement/profile matching only for this compilation target; `--features=disable_legacy_signing` disables signing. The test profile is removed when packaging the artifact. Normal device builds retain their default entitlement validation.

The resulting `NanoVoice-unsigned.ipa` is a compilation artifact, not an installable app. Workflow artifacts and build diagnostics are retained for seven days. A signed delivery workflow is not yet configured. Fork-relative submodule URLs were replaced with explicit upstream URLs so recursive checkout works from this repository.

The runner keeps its iOS simulator runtimes: Interface Builder needs these even when compiling a device-only app. Removing them caused `iOS 26.5 Platform Not Installed` during launch-screen compilation. Unused Xcode installations may still be removed to free space on the disposable runner.

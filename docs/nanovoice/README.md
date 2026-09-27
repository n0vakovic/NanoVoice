# NanoVoice

Personal Telegram iPhone client focused on two agent conversations and hands-free Walk mode. This is an independent fork, not an official Telegram app. Upstream source and license notices are preserved.

## Verified working milestone

Build 17: the owner confirmed the full loop on iPhone 14 Pro with AirPods on 2026-09-27: headset press records, the next press sends to the selected agent, and incoming replies play while the phone is locked in Walk mode. This is user-reported hardware validation, not an automated test claim. Local tests also cover incoming-message filtering and Opus capture duration across microphone sample rates.

The app is named NanoVoice with a purple/pink icon. The two conversation titles are currently personal defaults in `NanoVoiceHomeController.swift`; customize them for another account. Walk mode explicitly keeps a muted communication session active. Unmute records, mute sends; ending Walk mode discards unfinished input and releases the microphone. See `Tests/WalkLive/README.md` for implementation details and test commands.

## Rebuilding on Apple Silicon

The working device build used Xcode 26.6 / iOS SDK 26.5 and Bazel 8.4.2. Upstream `versions.json` still pins Xcode 26.2; the direct build below documents the tested override rather than changing the upstream pin. Install Xcode's Metal toolchain if requested. Clone recursively:

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

Credentials and signing files must never be committed. The inherited CI workflow is manual-only and uses upstream fake signing: it is not a configured NanoVoice delivery pipeline. Cloud CI remains future work.

## Upstream updates and cleanup

`origin` is the personal public repository; `upstream` is TelegramMessenger/Telegram-iOS. Fetch upstream and review/merge changes on a separate branch. The `nanovoice-v0.1.0` tag preserves the working milestone. Keep the upstream GPL license and attribution.

Bazel's output root is disposable and was approximately 25 GB. Preserve a signed app backup, private configuration/profile, and the signing key before deleting caches. Deleting these caches does not uninstall the app from the phone; the next build will be cold. Source and tests occupy less than 1 GB and are worth retaining.

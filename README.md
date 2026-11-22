# Telegram-iOS mod-gifts

An unsigned Telegram iOS build with **mod-to-mod gift transfers**: users of this modified
client can send each other collectible gifts that render as the stock gift bubble in the chat
and appear in the profile's Gifts tab. Stock Telegram clients see only a normal (near-empty)
text message; the gift payload rides inside it on a hidden zero-width marker.

Built on Windows (no Mac needed) via GitHub Actions macOS runners. Install with
[Sideloadly](https://sideloadly.io) + a free Apple ID.

## What the mod does

- **Send**: the attach menu's gift button opens a gift picker (the star-gift catalog the app
  already caches). Pick a gift, a collectible number, an optional message → it is sent as a
  normal text message carrying the hidden payload.
- **Receive**: the other mod client decodes the marker, strips it from the visible text, and
  synthesizes the same `starGiftUnique` action the official client renders for real gifts —
  so the gift bubble, the gift view screen and the profile Gifts tab all work unchanged.
- **Profile**: every received mod gift shows in the profile's Gifts tab (pinned ones first).
  Hiding/pinning is the recipient's local choice and persists.
- The animation model is NOT transmitted: the receiver resolves it from its own cached gift
  catalog by `giftId`, exactly like a real gift. If the receiver never loaded the gift store,
  the message stays plain text (nothing breaks).

## Repository layout

This repo contains only the diff (the upstream is tens of thousands of files):

- `patches/mod-gifts.patch` — changes to 9 upstream files, written against `UPSTREAM_REF`
  (release-13.2, commit `24638bc…`), applies with no fuzz.
- `newfiles/` — 7 new files (codec module + tests, resolver, profile store, picker screen).
- `scripts/apply_mods.sh` — applies the patch, copies the new files.
- `scripts/resign_profiles.py` — the bundled fake-codesigning profiles expired 2026-10-30;
  Bazel refuses expired profiles, so this bumps expiry to 2036 and re-signs them with the
  repo's own self-signed identity (Make.py verifies the CMS signature, a byte edit is not enough).
- `.github/workflows/build-unsigned-ipa.yml` — the build.

## Build

1. Push this repo to your GitHub (public repo → free macOS minutes).
2. Actions tab → **Build mod-gifts unsigned IPA** → Run workflow.
3. Wait ~90 minutes (first run; cached runs are faster). The artifact is
   `Telegram-modgift-unsigned.ipa`.

The build runs on the `xcode-27` runner image: macOS 27, Xcode 27.1 default — exactly what the
pinned upstream's `versions.json` declares, so no Xcode juggling is needed.

## Install on Windows (no Mac)

1. Install **web (non-Store) iTunes** and **web iCloud** from apple.com (Sideloadly needs their
   device drivers; the Microsoft Store versions cause NP_E_CONN_FAILED errors).
2. Download [Sideloadly](https://sideloadly.io) v0.71.0+.
3. Drag the IPA onto Sideloadly, enter your Apple ID (2FA code when asked), install to the
   connected iPhone.
4. On the phone: Settings → General → VPN & Device Management → trust your developer profile.

Free Apple ID limits: the profile expires **every 7 days** (re-sign by reconnecting the phone
and repeating step 3), max 3 sideloaded apps, 10 App IDs per rolling week. The IPA ships with
all extensions and the watch app stripped so it needs only one App ID. Push notifications do
not work on a free-account signing (expected). A paid developer account ($99/yr) removes the
7-day limit.

## Troubleshooting

- **Build fails at "provisioning profile ExpirationDate is in the past"** —
  `resign_profiles.py` did not run; check its log output.
- **Runner out of disk/RAM** — switch the workflow's `runs-on` to `xcode-27-xlarge` (paid
  larger runner) or free more space in the "Free disk space" step.
- **Patch fails to apply** — upstream moved; re-pin `UPSTREAM_REF` and regenerate the patch.
- **Gift message shows as plain text on the other side** — the receiver's app has not loaded
  the gift catalog yet (open the gift store once), or the receiver runs a stock client.

## License

Telegram-iOS is GPL-2.0; this repository's patch and scripts are provided under the same
terms. The pinned upstream source is cloned at build time from
https://github.com/TelegramMessenger/Telegram-iOS

# Build and install

## Requirements

- macOS with **Xcode 27** (the project targets the iOS 27 SDK and runs on iOS 26 or later)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An iPhone on iOS 26 or later, connected by cable or on the same Wi-Fi as the Mac
- An Apple ID signed in to Xcode (**Xcode > Settings > Accounts**). A free personal team works

The Xcode project is generated from `project.yml` and is not committed. `install-iphone.sh` runs `xcodegen generate` for you.

## 1. Secrets

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

Edit `Config/Secrets.xcconfig`:

| Key | Needed | What |
|---|---|---|
| `TMDB_TOKEN` | yes | TMDB **read access token** (v4) from [themoviedb.org/settings/api](https://www.themoviedb.org/settings/api) |
| `SUBDL_KEY` | no | SubDL API key from [subdl.com/panel/api](https://subdl.com/panel/api) |

The values are bundled into the app's `Info.plist`, so the app needs no setup on first launch. Anyone who gets your built app can read them.
A TMDB read token only gives read access to public metadata, which is fine for your own phone. **Do not distribute builds made with your keys.**
You can also leave both empty and type them in **My Stuff > Settings**; values saved in the app always win.

## 2. Signing

```bash
cp Config/Signing.example.xcconfig Config/Signing.xcconfig
```

| Key | What |
|---|---|
| `CF_BUNDLE_ID` | A bundle identifier unique to you, for example `com.yourname.cineflix` |
| `DEVELOPMENT_TEAM` | Your Apple Developer Team ID (10 characters) from Xcode > Settings > Accounts, or developer.apple.com > Membership |

Without this file the project uses `com.example.cineflix` and no team, which builds for the simulator but cannot be installed on a phone.

## 3. Prepare the iPhone (once)

1. Turn on **Settings > Privacy & Security > Developer Mode** and restart the phone when asked.
2. Connect the phone with a cable, unlock it and tap **Trust**.
3. To install over Wi-Fi later, enable **Connect via network** for the device in Xcode > Window > Devices and Simulators.

## 4. Build and install

```bash
./install-iphone.sh                       # every paired iPhone
./install-iphone.sh <device-id> ...       # only these
./install-iphone.sh --no-launch ...       # do not open the app afterwards
```

Find device ids with `scripts/list-iphones.sh` (it prints id, name and whether the phone is paired).
The first time, on the phone open **Settings > General > VPN & Device Management**, tap your Apple Development certificate and trust it.

## Free account limits

With a free personal team an installed app **expires after 7 days**, and Apple limits how many apps and devices you can use.
Run `./install-iphone.sh` again to renew, or set up the [daily automatic reinstall](auto-install.md).
A paid Apple Developer Program account removes the 7-day limit and allows TestFlight.

## Build without a phone

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
xcodegen generate
xcodebuild build -project CineFlix.xcodeproj -scheme CineFlix \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Or open `CineFlix.xcodeproj` in Xcode and run it on a simulator.

## Adding another iPhone

1. Turn on Developer Mode on the phone, connect it, tap **Trust**.
2. Run `./install-iphone.sh`. The daily job picks the phone up automatically from then on.

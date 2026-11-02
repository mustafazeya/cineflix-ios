# Troubleshooting

## "No paired iPhone found" or the phone is skipped
Connect the phone with a cable, unlock it and tap **Trust**. Turn on Developer Mode (**Settings > Privacy & Security > Developer Mode**) and restart.
List what the Mac sees with `scripts/list-iphones.sh`; the last column must say `paired`.

## Signing errors, or "No Team" / bundle id already in use
Create `Config/Signing.xcconfig` from the example with your own `DEVELOPMENT_TEAM` and a unique `CF_BUNDLE_ID`. A free team cannot use a bundle id
already registered by another account, so pick your own.

## The app will not open: "Untrusted Developer"
On the iPhone: **Settings > General > VPN & Device Management**, tap your Apple Development certificate and trust it.

## The app stopped opening after a week
A free Apple team signs for 7 days. Run `./install-iphone.sh`, or set up the [automatic reinstall](auto-install.md).

## The app asks for a TMDB token
Put it in `Config/Secrets.xcconfig` and rebuild, or enter it under **My Stuff > Settings**.

## Play says the title is not available, or nothing plays
- Use your server's network address, not `localhost`. On the phone `localhost` is the phone.
- The phone must be on the same network as the server, and iOS asks for local network permission the first time. Allow it.
- A `404` from your server means "not available". Test `{Stream URL}/movie/{tmdbId}` in Safari on the phone.
- Use H.264 or HEVC with AAC in MP4 or HLS.

## Trailer does not play
Trailers use a hosted https page (see [Configuration](configuration.md#trailer-page)). Check the page URL in Settings. Some videos cannot be embedded.

## Subtitle search says "did not accept your API key"
Check the SubDL key in Settings or `Secrets.xcconfig`. SubDL also has daily download limits and shows a message when you reach them.

## `xcodegen: command not found`
`brew install xcodegen`.

## The build cannot find the iOS 27 SDK
This project needs Xcode 27. Check with `xcodebuild -version`.

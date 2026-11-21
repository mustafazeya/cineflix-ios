# Testing

`UITests/CineFlixUITests.swift` contains end-to-end UI tests that run in the simulator against the real TMDB and SubDL services,
so they need your keys in `Config/Secrets.xcconfig` and an internet connection.

| Test class | What it covers |
|---|---|
| `CineFlixUITests` | Home, Search, title page, playback, Mark watched, My Stuff and Browse |
| `WatchedUITests` | Continue Watching long-press menu (mark watched, remove) and marking single episodes |
| `RatingsUITests` | Thumbs up and down, and the "Because you watched" rows |
| `KidsUITests` | Kids profile filtering, PIN gate, badges, and the profile editor |
| `KidsRealTMDBUITests` | The kids filter against the live TMDB ratings |
| `ResumeUITests` | Saved links resume at the synced position, push the new position, "Start over" and finished videos delete it, nothing is saved before 10 seconds |
| `NativeSwitchUITests` | "Play natively" on a blob: page: stream found by fetch, XHR, `src` and hls.js, master playlist preferred, Referer and cookie sent, position kept, back to the page when native playback fails |
| `SubtitleUITests` | Subtitle search, choosing a result, the subtitle appearing, and turning it off, for a web player page and a native video |

## Prerequisites

The tests play a title from a local server, so start the reference media server from the TV repository first:

```bash
git clone https://github.com/mustafazeya/cineflix-webos.git
node cineflix-webos/tools/media-server.js --port 8090
```

`SubtitleUITests` also needs a plain player page without the bridge on `http://localhost:8112`. Any page with a single `<video>` pointing to a
public test video works. Skip that case with `-only-testing` if you do not have one.

The classes in `UITests/FeatureUITests.swift` run against two local stand-ins instead of the live services, so start both first
(Node, no packages needed). `KidsRealTMDBUITests` only replaces the sync server, so it needs your TMDB key:

```bash
node scripts/ui-test-servers/mock-sync.js   # sync server on :8150 (profiles, PINs, items; /_test/* helpers)
node scripts/ui-test-servers/mock-tmdb.js   # TMDB with every rating kind on :8151
node scripts/ui-test-servers/mock-media.js <short video file>   # your media server on :8160 (NextEpisodeUITests: a clip of about 25 seconds)
node scripts/ui-test-servers/mock-media.js <video of about 400 s>   # the same server for ResumeUITests, which seeks to 60 s and 380 s
node scripts/ui-test-servers/mock-page.js <video.mp4>           # a player page that plays through a blob: address on :8161 (NativeSwitchUITests)
```

`ResumeUITests` and `NextEpisodeUITests` both use port 8160 with a different clip, so run them one after the other. The tests cannot try
AirPlay or Chromecast to a real receiver, and the page server plays a blob made from an MP4, not real hls.js or MediaSource output.

The app is pointed at them with `-cf.syncServer http://127.0.0.1:8150 -cf.tmdbBase http://127.0.0.1:8151/3 -cf.tmdbToken test`.

## Run

```bash
xcodegen generate
pod install
xcodebuild test -workspace CineFlix.xcworkspace -scheme CineFlix \
  -destination 'platform=iOS Simulator,name=<a simulator you have>' \
  -only-testing:CineFlixUITests/CineFlixUITests
```

List simulators with `xcrun simctl list devices available`.

The tests use launch arguments to configure the app: `-cf.streamBase`, `-cf.streamType`, `-cf.hideWatched`, `-cf.resetLibrary`, `-cf.syncServer`,
`-cf.tmdbBase`, `-cf.tmdbToken` and `-cf.testClock` (adds a nearly invisible element that exposes the playing position), `-cf.noCast` (skips looking for Chromecasts, whose local network prompt would cover the screen).

## Build check

CI builds the app for the simulator without signing. You can do the same locally; see [Build and install](build-and-install.md#build-without-a-phone).

## Manual checks after changes

1. Home loads and scrolls, and posters open the title page.
2. Play a title, leave, and check Resume and Continue Watching.
3. Subtitles on a movie and a series episode: pause freezes the text, seeking moves it.
4. Browse filters and Search.
5. Rotate to landscape in the player.

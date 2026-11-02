# Testing

`UITests/CineFlixUITests.swift` contains end-to-end UI tests that run in the simulator against the real TMDB and SubDL services,
so they need your keys in `Config/Secrets.xcconfig` and an internet connection.

| Test class | What it covers |
|---|---|
| `CineFlixUITests` | Home, Search, title page, playback, Mark watched, My Stuff and Browse |
| `SubtitleUITests` | Subtitle search, choosing a result, the subtitle appearing, and turning it off, for a web player page and a native video |

## Prerequisites

The tests play a title from a local server, so start the reference media server from the TV repository first:

```bash
git clone https://github.com/mustafazeya/cineflix-webos.git
node cineflix-webos/tools/media-server.js --port 8090
```

`SubtitleUITests` also needs a plain player page without the bridge on `http://localhost:8112`. Any page with a single `<video>` pointing to a
public test video works. Skip that case with `-only-testing` if you do not have one.

## Run

```bash
xcodegen generate
xcodebuild test -project CineFlix.xcodeproj -scheme CineFlix \
  -destination 'platform=iOS Simulator,name=<a simulator you have>' \
  -only-testing:CineFlixUITests/CineFlixUITests
```

List simulators with `xcrun simctl list devices available`.

The tests use launch arguments to configure the app: `-cf.streamBase`, `-cf.streamType`, `-cf.hideWatched` and `-cf.resetLibrary`.

## Build check

CI builds the app for the simulator without signing. You can do the same locally; see [Build and install](build-and-install.md#build-without-a-phone).

## Manual checks after changes

1. Home loads and scrolls, and posters open the title page.
2. Play a title, leave, and check Resume and Continue Watching.
3. Subtitles on a movie and a series episode: pause freezes the text, seeking moves it.
4. Browse filters and Search.
5. Rotate to landscape in the player.

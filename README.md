# CineFlix for iPhone

[![CI](https://github.com/mustafazeya/cineflix-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/mustafazeya/cineflix-ios/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A native SwiftUI catalog app for iPhone. Posters, backdrops, cast, trailers and seasons come from [TMDB](https://www.themoviedb.org/).
**Video plays only from a media server that you run and have the rights to use.** No ads, no trackers, no accounts, no third-party video hosts.

> **This project does not provide, host, index or link to any video content.** It is a client for your own server.
> You are responsible for having the rights to everything you play. See [Legal](#legal).

The LG TV version lives in [cineflix-webos](https://github.com/mustafazeya/cineflix-webos) and uses the same server contract.

## Features

- **Home**: hero carousel with title logos, Continue Watching, Recently Added to your library, Top 10 Today, new releases, popular and top rated, coming soon, genres
- **Title page**: logo, rating, runtime, age rating, Play or Resume, My List, Mark watched, Trailer, Share, seasons and episodes (watched checks and progress), cast (tap to browse by actor), More Like This
- **Browse**: movies or TV, sort, genre, year or decade, actor, minimum rating, hide watched, endless scrolling
- **Search** with trending suggestions
- **My Stuff**: Continue Watching, My List, Already Watched, Settings
- **Player**: native AVPlayer for MP4 and HLS with resume, Picture in Picture, AirPlay and auto next episode, or an in-app web view for servers that return their own player page
- **Subtitle search** from SubDL for the exact movie or episode, kept in step with the real video clock ([details](docs/subtitles.md))
- Everything personal (list, progress, settings) is stored on the device only

## Requirements

- A Mac with **Xcode 27** and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An iPhone on **iOS 26 or later**, and an Apple ID (a free personal team is enough to run on your own device)
- A free [TMDB](https://www.themoviedb.org/settings/api) API read access token
- A media server that follows the [server contract](https://github.com/mustafazeya/cineflix-webos/blob/main/docs/media-server-api.md)
  (the TV repository includes a reference server for testing)
- Optional: a free [SubDL](https://subdl.com/panel/api) API key

## Quick start

```bash
git clone https://github.com/mustafazeya/cineflix-ios.git
cd cineflix-ios

cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig     # add your TMDB token (and optional SubDL key)
cp Config/Signing.example.xcconfig Config/Signing.xcconfig     # add your bundle id and Apple team id

./install-iphone.sh                                           # build, install and launch on every paired iPhone
```

First install only: on the iPhone open **Settings > General > VPN & Device Management** and trust your developer certificate.
Both `Secrets.xcconfig` and `Signing.xcconfig` are git-ignored. Full steps, including pairing and Developer Mode, are in
[docs/build-and-install.md](docs/build-and-install.md).

Then open **My Stuff > Settings** and enter your server's Stream URL, for example `http://192.168.1.20:8090`. Use your server's network address, not `localhost`.

## Documentation

| Topic | |
|---|---|
| [Build and install](docs/build-and-install.md) | Signing, secrets, pairing a phone, Developer Mode, the 7-day limit |
| [Configuration](docs/configuration.md) | Every setting and where it comes from |
| [Media server](docs/media-server.md) | The contract your server implements, player pages |
| [Subtitles](docs/subtitles.md) | SubDL search, clock rules, season packs |
| [Automatic reinstall](docs/auto-install.md) | Keep a free-team install fresh with a daily job |
| [Architecture](docs/architecture.md) | Code layout and how the pieces fit |
| [Testing](docs/testing.md) | UI tests and how to run them |
| [Troubleshooting](docs/troubleshooting.md) | Common problems and fixes |

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, see [SECURITY.md](SECURITY.md).

## Legal

- CineFlix contains **no media** and no code that locates, scrapes or bypasses protection on content. It plays what *your* server returns.
- You must have the legal right to store and stream everything you serve. The authors accept no responsibility for how this software is used.
- This product uses the TMDB API but is not endorsed or certified by TMDB. Subtitles are provided by SubDL, and you must follow their terms.
- Apple, iPhone and iOS are trademarks of Apple Inc. This project is not affiliated with or endorsed by Apple or anyone else named here.

Code is released under the [MIT License](LICENSE). Third-party components and the terms for the name and artwork are listed in [NOTICE.md](NOTICE.md).

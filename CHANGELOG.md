# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Long-press a Continue Watching card to mark the title watched or remove it from the row; single episodes can be marked watched or not
- Kids profiles with a maximum rating (G, PG, PG-13), a content filter built on US ratings, and an optional 4 to 6 digit PIN; a PIN-protected
  kids profile asks for it before the person switches profile, signs out or opens Settings
- Thumbs up and thumbs down on title pages (synced as `rating` items) and up to two "Because you watched" rows on Home
- Chromecast: a Cast button on Home and in the player; what you play goes to the TV and the phone becomes its remote (seek, play/pause, volume, subtitles, next episode). MEGA files and other links are served to the TV from the phone. AirPlay button in the player for normal video links

## [1.0.0] - 2026-11-02

First public release.

### Added
- Home with hero carousel, rows, Top 10 and Continue Watching; title pages with seasons, cast and trailers
- Browse filters: type, sort, genre, year or decade, actor, minimum rating, hide watched
- Search, My List, Already Watched and Settings
- Native AVPlayer playback (MP4 and HLS) with resume, Picture in Picture, AirPlay and auto next episode
- In-app web view for servers that return their own player page, with no change needed on the page
- Subtitle search through SubDL with a real-clock subtitle engine, per-title memory, delay, and season pack handling for series
- Scripts to install on paired iPhones and a LaunchAgent for the daily reinstall on a free Apple team
- Documentation in `docs/`

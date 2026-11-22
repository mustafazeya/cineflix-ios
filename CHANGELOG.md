# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Long-press a Continue Watching card to mark the title watched or remove it from the row; single episodes can be marked watched or not
- Kids profiles with a maximum rating (G, PG, PG-13), a content filter built on US ratings, and an optional 4 to 6 digit PIN; a PIN-protected
  kids profile asks for it before the person switches profile, signs out or opens Settings
- Thumbs up and thumbs down on title pages (synced as `rating` items) and up to two "Because you watched" rows on Home
- Next episode card like Netflix: in the last 30 seconds of an episode (or at its end) a card shows the next episode with a 10 second countdown, Play now and Watch credits; a Next episode button is always in the player; season rollover; new Autoplay next episode setting
- Resume for My Videos and MEGA files: the player remembers the position of a saved link or a MEGA file (about every 5 seconds, never in the first 10 seconds, forgotten after 95%) and every device on the profile resumes at the same place. Synced as `resume` items (`v:<videoId>`, `m:<videoId>:<nodeId>`). My Videos and MEGA folder rows show a thin progress bar and "Resume 12:34", with a "Start over" action. Autoplay to the next MEGA file uses that file's own saved position. Existing accounts download everything once more after updating, so older data is picked up
- Media server pages play in the app's own player by themselves: a page that plays through MediaSource or a blob: address only sends sound to AirPlay. The page is opened out of sight and watched for the stream it loads (XMLHttpRequest, fetch, `src`, `<source>`, hls.js `loadSource`), then that stream plays in AVPlayer, fetched through the phone with the page's Referer, User-Agent and cookies, so AirPlay and Chromecast show the picture. The page is shown only when no stream appears within 12 seconds (it may need a tap on its play button) or when the stream cannot be played, and the player then says why
- Server page streams are found by what they are: video element addresses with no file name, addresses named in the page's own JSON, loads the browser makes for a video element, and playlists under any name. The app presses the page's play button while the page is out of sight, waits up to 45 seconds for a busy page, and shows a note of what the page loaded when nothing playable turned up
- Player buttons fade out a few seconds after the last touch and come back on a touch, a pause, or the next-episode card; the system player's own close and AirPlay buttons are no longer covered by duplicates
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

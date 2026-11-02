# Subtitles

CineFlix searches subtitles on the internet through [SubDL](https://subdl.com), so your own player page needs no subtitle code.

## Setup

1. Get a free API key at [subdl.com/panel/api](https://subdl.com/panel/api).
2. Put it in `Config/Secrets.xcconfig` as `SUBDL_KEY`, or enter it under **My Stuff > Settings > Subtitles**.
3. Set the languages to look for, for example `EN` or `EN,SV`. The first language is listed first.

## Using it

While a title plays, tap the **subtitles** button. CineFlix lists subtitles for that exact movie or episode.
Tap one: it is downloaded, drawn over the video and remembered for that title. Delay buttons shift the timing if a file is slightly off.
Results are sorted by your language order, then regular before hearing-impaired.

## How the clock works

Subtitles follow the real video clock and nothing else.

- They **stop when the video pauses**, stalls, buffers or ends, and they **jump when you seek**.
- If the clock goes quiet for more than one second the text stops rather than guessing.
- The native player (MP4 and HLS) uses the AVPlayer time. For a web player page, CineFlix reads the page's biggest `<video>`, in any nested frame,
  so no change to your page is needed.

## TV series: season packs

For episodes, SubDL often only has a zip containing a whole season.

- Results made for your exact episode come first. Full-season zips follow, labelled "Full season zip, episode N picked for you".
- When you choose one, CineFlix opens the zip and loads only the file for the episode you are watching. It recognises common names
  such as `S01E03`, `1x03`, `[3.10]`, `Episode 3` and `03 - Title`.
- If a pack has no file for your episode you get a message to try another result, and a wrong episode is never loaded.

## Details

- Search: `GET https://api.subdl.com/api/v1/subtitles` with the TMDB id, `type`, and for series `season_number` and `episode_number`.
- Download: `https://dl.subdl.com{url}`. The API key is stripped from download links; it is not needed to download.
- Formats: SRT and WebVTT, zipped or plain. Legacy encodings are guessed from the language. HTML italics are rendered and ASS codes are removed.
- A rejected key shows "SubDL did not accept your API key". SubDL's daily download limit shows a clear message.
- The 12 most recent choices are remembered on the device. The code is in `Sources/Core/Subtitles.swift` and `Sources/Features/Player/`.

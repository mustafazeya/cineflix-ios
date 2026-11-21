# Media server

CineFlix plays video only from a server you control. The contract is the same as in the TV app, so one server works for both.
The full specification, with request and response examples and a zero-dependency reference server, is in the TV repository:

**[cineflix-webos / docs / media-server-api.md](https://github.com/mustafazeya/cineflix-webos/blob/main/docs/media-server-api.md)**

## Summary

```
{Stream URL}/movie/{tmdbId}
{Stream URL}/tv/{tmdbId}/{season}/{episode}
{Stream URL or Catalog URL}/catalog          (optional)
```

- Each stream URL returns a video (MP4 or HLS, directly or by redirect) or a web page with its own player. A `404` means "not available".
- `/catalog` returns `{ "items": [ { "tmdbId": 10378, "type": "movie", "addedAt": "..." } ] }` and gives Available badges and Recently Added.
  A `404` there means every title is treated as playable.
- A catalog server can also offer `GET /streams/movie/{id}` and `/streams/tv/{id}/{season}/{episode}` with several sources and subtitles.
- Use your server's network address, not `localhost`, because `localhost` on the phone means the phone.

## Player pages

If the stream URL returns an HTML page, the app opens it in an in-app web view with its own player. CineFlix reads the page's `<video>`
element, including inside nested frames, to follow the real playback state. That gives resume and Continue Watching, next episode, and
subtitles in step with the video, **with no change to your page**.

The optional [page bridge](https://github.com/mustafazeya/cineflix-webos/blob/main/docs/player-pages.md#the-optional-page-bridge)
(`tools/makeflix-page-bridge.js` in the TV repository) works on iPhone too: it reports progress and the end of playback with the same messages
(`source: 'makeflix-page'`).

## AirPlay and pages that play through MediaSource

Many player pages feed hls.js or MediaSource into a `blob:` address. The iPhone can send the sound of such a page to AirPlay but not the
picture. While a page is showing, the app watches which stream address it loads (an HLS master playlist, an `.m3u8`, or a `.mp4`, `.webm`
or `.mov` file), and a **Play natively** button appears in the player's top bar. It opens that address in the native player at the page
video's position, with the page's Referer, User-Agent and cookies, and AirPlay and Chromecast then show the picture. The page remains
the default and **Back to page** returns to it. If the stream does not play outside the page, the player says so and offers the page.

This works for streams a plain player can fetch. A stream that needs a token the page builds in JavaScript on every request, is protected
(DRM) or is only reachable through the page's own scripts will not play natively. AirPlay hands the address to the Apple TV, which fetches
it by itself, so a server that insists on the page's Referer or cookie may not play on the receiver even when it plays on the phone.

## Codecs

H.264 or HEVC video with AAC audio in MP4 or HLS plays natively through AVPlayer, with Picture in Picture and AirPlay.

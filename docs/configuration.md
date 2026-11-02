# Configuration

Settings are saved on the device. Values you save in the app always win over the defaults that were bundled at build time.

Open **My Stuff > Settings**.

| Setting | Default | Meaning |
|---|---|---|
| TMDB read access token | bundled from `TMDB_TOKEN` | Required. Used for all catalog data |
| Language | `en-US` | TMDB language for titles and descriptions |
| Region | empty | Region for release dates and certifications, for example `US` |
| Stream URL | empty | Plays `{url}/movie/{tmdbId}` and `{url}/tv/{tmdbId}/{season}/{episode}` |
| Returns | Detect automatically | A video (MP4 or HLS), a web page with its own player, or detect automatically |
| Catalog URL | empty | Optional. Defaults to the Stream URL. Serves `/catalog` for Available badges and Recently Added |
| Access token | empty | Optional. Sent to your server as a bearer token |
| SubDL API key | bundled from `SUBDL_KEY` | Enables subtitle search |
| Subtitle languages | `EN` | Comma separated, for example `EN,SV` |
| Trailer page | maintainer's hosted page | https page that wraps YouTube trailers; see below |

The server contract is documented in [media-server.md](media-server.md).

## Build-time values

| File | Keys | Purpose |
|---|---|---|
| `Config/Secrets.xcconfig` (git-ignored) | `TMDB_TOKEN`, `SUBDL_KEY` | Bundled into `Info.plist` as `TMDBToken` and `SubDLKey` |
| `Config/Signing.xcconfig` (git-ignored) | `CF_BUNDLE_ID`, `DEVELOPMENT_TEAM` | Bundle id and Apple team for code signing |
| `Config/App.xcconfig` | defaults and includes | Do not put secrets here |

## Trailer page

YouTube rejects embeds that have no referring page. The app therefore loads trailers through a small https wrapper page. The default is the
maintainer's page on GitHub Pages; you can host your own copy and set it in Settings. The page and how to host it are described in the
[TV repository](https://github.com/mustafazeya/cineflix-webos/blob/main/docs/trailer-page.md).

## Network access

The app allows plain `http://` connections (`NSAllowsArbitraryLoads`) so it can reach a media server on your local network, and it declares
a local-network usage description. If your server is on the internet, serve it over HTTPS.

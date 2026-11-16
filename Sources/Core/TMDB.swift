import Foundation

enum MediaType: String, Codable, Hashable, Sendable {
    case movie, tv

    var label: String { self == .movie ? "Movie" : "Series" }
}

struct MediaRef: Hashable, Codable, Sendable {
    let type: MediaType
    let id: Int

    var key: String { "\(type.rawValue):\(id)" }
}

struct MediaItem: Hashable, Codable, Sendable {
    var id: Int
    var type: MediaType
    var title: String
    var overview: String = ""
    var posterPath: String?
    var backdropPath: String?
    var voteAverage: Double = 0
    var voteCount: Int = 0
    var date: String?
    var genreIDs: [Int] = []
    var popularity: Double = 0
    var episodeCount: Int = 0

    var ref: MediaRef { MediaRef(type: type, id: id) }
    var year: String? { date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    var rating: String? { voteAverage > 0 ? String(format: "%.1f", voteAverage) : nil }
}

struct Genre: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
}

struct SeasonInfo: Codable, Hashable, Sendable {
    let seasonNumber: Int
    let episodeCount: Int
    let name: String?
}

struct Episode: Codable, Hashable, Sendable, Identifiable {
    let episodeNumber: Int
    let name: String?
    let overview: String?
    let stillPath: String?
    let airDate: String?
    let runtime: Int?

    var id: Int { episodeNumber }
    var aired: Bool {
        guard let airDate, !airDate.isEmpty else { return true }
        return airDate <= TMDB.today
    }
}

struct CastMember: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?
}

struct Person: Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let profilePath: String?
    let department: String?
    let knownFor: String
}

struct TitleDetails: Sendable {
    var item: MediaItem
    var tagline: String?
    var runtime: Int?
    var numberOfSeasons: Int
    var seasons: [SeasonInfo]
    var genres: [Genre]
    var cast: [CastMember]
    var credit: String?
    var trailerKey: String?
    var recommendations: [MediaItem]
    var certification: String?
    var logoPath: String?
}

struct ItemPage: Sendable {
    var items: [MediaItem]
    var totalPages: Int
}

// MARK: - Raw TMDB payloads

private struct RawItem: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let voteCount: Int?
    let releaseDate: String?
    let firstAirDate: String?
    let genreIds: [Int]?
    let popularity: Double?
    let episodeCount: Int?

    func item(default type: MediaType?) -> MediaItem? {
        guard let t = mediaType.flatMap(MediaType.init(rawValue:)) ?? type else { return nil }
        let date = (releaseDate?.isEmpty == false) ? releaseDate : firstAirDate
        return MediaItem(id: id, type: t, title: title ?? name ?? "", overview: overview ?? "",
                         posterPath: posterPath, backdropPath: backdropPath,
                         voteAverage: voteAverage ?? 0, voteCount: voteCount ?? 0,
                         date: date, genreIDs: genreIds ?? [], popularity: popularity ?? 0,
                         episodeCount: episodeCount ?? 0)
    }
}

private struct RawPage: Decodable {
    let results: [RawItem]
    let totalPages: Int?
}

private struct RawDetails: Decodable {
    struct Credits: Decodable {
        struct Crew: Decodable { let job: String?; let name: String }
        let cast: [CastMember]?
        let crew: [Crew]?
    }
    struct Videos: Decodable {
        struct Video: Decodable { let key: String; let site: String; let type: String; let official: Bool? }
        let results: [Video]
    }
    struct Recs: Decodable { let results: [RawItem] }
    struct ReleaseDates: Decodable {
        struct Country: Decodable {
            struct Release: Decodable { let certification: String? }
            let iso31661: String
            let releaseDates: [Release]
        }
        let results: [Country]
    }
    struct ContentRatings: Decodable {
        struct Rating: Decodable { let iso31661: String; let rating: String? }
        let results: [Rating]
    }
    struct Images: Decodable {
        struct Logo: Decodable { let filePath: String; let iso6391: String?; let voteAverage: Double? }
        let logos: [Logo]?
    }
    struct Creator: Decodable { let name: String }

    let id: Int
    let adult: Bool?
    let title: String?
    let name: String?
    let overview: String?
    let tagline: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let voteCount: Int?
    let releaseDate: String?
    let firstAirDate: String?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let numberOfSeasons: Int?
    let genres: [Genre]?
    let seasons: [SeasonInfo]?
    let credits: Credits?
    let createdBy: [Creator]?
    let videos: Videos?
    let recommendations: Recs?
    let releaseDates: ReleaseDates?
    let contentRatings: ContentRatings?
    let images: Images?
}

private struct RawSeason: Decodable { let episodes: [Episode] }
private struct RawGenres: Decodable { let genres: [Genre] }
private struct RawCredits: Decodable { let cast: [RawItem] }
private struct RawPeople: Decodable {
    struct P: Decodable {
        let id: Int
        let name: String
        let profilePath: String?
        let knownForDepartment: String?
        let knownFor: [RawItem]?
    }
    let results: [P]
}
private struct RawImages: Decodable {
    let logos: [RawDetails.Images.Logo]?
}

// MARK: - Response cache

actor ResponseCache {
    static let shared = ResponseCache()
    private var store: [URL: (Date, Data)] = [:]

    func get(_ url: URL, ttl: TimeInterval) -> Data? {
        guard let (at, data) = store[url], Date().timeIntervalSince(at) < ttl else { return nil }
        return data
    }

    func set(_ url: URL, _ data: Data) {
        if store.count > 400 { store.removeAll() }
        store[url] = (Date(), data)
    }

    func clear() { store.removeAll() }
}

/// "Because you watched" lists, kept for the session so the Home screen does not ask again.
final class RecommendationCache {
    static let shared = RecommendationCache()
    private var store: [String: [MediaItem]] = [:]
    func get(_ key: String) -> [MediaItem]? { store[key] }
    func set(_ key: String, _ items: [MediaItem]) { store[key] = items }
}

// MARK: - Client

struct TMDB: Sendable {
    let token: String
    let language: String
    let region: String
    /// Set while a kids profile is active. Everything this client returns is then limited by the policy.
    var kids: KidsPolicy?

    /// UI tests point this at a local stand-in with -cf.tmdbBase.
    nonisolated(unsafe) static var endpoint = UserDefaults.standard.string(forKey: "cf.tmdbBase") ?? "https://api.themoviedb.org/3"

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func image(_ path: String?, _ size: String = "w342") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    enum Failure: LocalizedError {
        case noToken
        case http(Int)
        case blocked

        var errorDescription: String? {
            switch self {
            case .blocked: "Not available on this profile"
            case .noToken: "Add your TMDB token in Settings."
            case .http(let code): "TMDB request failed (\(code))."
            }
        }
    }

    private func fetch<T: Decodable>(_ path: String, _ query: [String: String] = [:], ttl: TimeInterval = 1800) async throws -> T {
        guard !token.isEmpty else { throw Failure.noToken }
        var q = query
        if q["language"] == nil { q["language"] = language }
        var headers = ["Accept": "application/json"]
        if token.count > 40 { headers["Authorization"] = "Bearer \(token)" } else { q["api_key"] = token }

        if kids != nil { q["include_adult"] = "false" }
        var comps = URLComponents(string: Self.endpoint + path)!
        comps.queryItems = q.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let url = comps.url!

        let data: Data
        if let cached = await ResponseCache.shared.get(url, ttl: ttl) {
            data = cached
        } else {
            var req = URLRequest(url: url, timeoutInterval: 15)
            headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw Failure.http(code) }
            await ResponseCache.shared.set(url, d)
            data = d
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }

    private func playable(_ raw: [RawItem], _ type: MediaType?) -> [MediaItem] {
        raw.compactMap { $0.item(default: type) }.filter { $0.posterPath != nil || $0.backdropPath != nil }
    }

    /// For a kids profile, drops everything that is not kid-safe. Other profiles get the list unchanged.
    private func limited(_ items: [MediaItem]) async -> [MediaItem] {
        guard let kids else { return items }
        return await KidsFilter.shared.filter(items, policy: kids, tmdb: self)
    }

    // MARK: Ratings

    /// A title's US maturity rating: movies from /movie/ID/release_dates, series from /tv/ID/content_ratings.
    func usRating(_ ref: MediaRef) async -> RatingLookup {
        do {
            if ref.type == .movie {
                let r: RawDetails.ReleaseDates = try await fetch("/movie/\(ref.id)/release_dates", ttl: 86400)
                return .found(Self.movieRating(r))
            }
            let r: RawDetails.ContentRatings = try await fetch("/tv/\(ref.id)/content_ratings", ttl: 86400)
            return .found(Self.tvRating(r))
        } catch {
            return .failed
        }
    }

    fileprivate static func movieRating(_ r: RawDetails.ReleaseDates?) -> MaturityRating? {
        let us = (r?.results ?? []).filter { $0.iso31661 == "US" }.flatMap(\.releaseDates)
        return MaturityRating.strictest(us.map { MaturityRating(movieCertification: $0.certification) })
    }

    fileprivate static func tvRating(_ r: RawDetails.ContentRatings?) -> MaturityRating? {
        MaturityRating.strictest((r?.results ?? []).filter { $0.iso31661 == "US" }.map { MaturityRating(tvRating: $0.rating) })
    }

    // MARK: Lists

    func trending(_ type: MediaType?, week: Bool = false) async throws -> [MediaItem] {
        let p: RawPage = try await fetch("/trending/\(type?.rawValue ?? "all")/\(week ? "week" : "day")")
        return await limited(playable(p.results, type))
    }

    /// kind: popular, top_rated, now_playing, upcoming, on_the_air, airing_today
    func list(_ type: MediaType, _ kind: String, page: Int = 1) async throws -> ItemPage {
        let p: RawPage = try await fetch("/\(type.rawValue)/\(kind)", ["page": String(page), "region": region])
        return ItemPage(items: await limited(playable(p.results, type)), totalPages: p.totalPages ?? 1)
    }

    func discover(_ type: MediaType, _ params: [String: String]) async throws -> ItemPage {
        var q = ["sort_by": "popularity.desc", "vote_count.gte": "50"]
        params.forEach { q[$0.key] = $0.value }
        if let kids { q = kids.discover(type, q) }
        let p: RawPage = try await fetch("/discover/\(type.rawValue)", q)
        return ItemPage(items: await limited(playable(p.results, type)), totalPages: p.totalPages ?? 1)
    }

    func search(_ query: String) async throws -> [MediaItem] {
        let p: RawPage = try await fetch("/search/multi", ["query": query, "include_adult": "false"], ttl: 300)
        return await limited(playable(p.results, nil))
    }

    func genres(_ type: MediaType) async throws -> [Genre] {
        let g: RawGenres = try await fetch("/genre/\(type.rawValue)/list", ttl: 86400)
        return g.genres
    }

    // MARK: People

    private func people(_ raw: RawPeople) -> [Person] {
        raw.results.map { p in
            let known = (p.knownFor ?? []).compactMap { $0.title ?? $0.name }.prefix(2).joined(separator: ", ")
            return Person(id: p.id, name: p.name, profilePath: p.profilePath, department: p.knownForDepartment, knownFor: known)
        }
    }

    func searchPeople(_ query: String) async throws -> [Person] {
        let r: RawPeople = try await fetch("/search/person", ["query": query, "include_adult": "false"], ttl: 300)
        return people(r)
    }

    func popularPeople() async throws -> [Person] {
        let r: RawPeople = try await fetch("/person/popular")
        return people(r).filter { $0.department == "Acting" }
    }

    func personCredits(_ id: Int, _ type: MediaType) async throws -> [MediaItem] {
        let r: RawCredits = try await fetch("/person/\(id)/\(type == .tv ? "tv_credits" : "movie_credits")")
        return await limited(playable(r.cast, type))
    }

    // MARK: Titles

    func season(_ id: Int, _ number: Int) async throws -> [Episode] {
        let s: RawSeason = try await fetch("/tv/\(id)/season/\(number)")
        return s.episodes
    }

    func logo(_ ref: MediaRef) async -> String? {
        let lang = String(language.prefix(2))
        guard let r: RawImages = try? await fetch("/\(ref.type.rawValue)/\(ref.id)/images",
                                                  ["language": "", "include_image_language": "\(lang),en,null"], ttl: 86400)
        else { return nil }
        return Self.bestLogo(r.logos ?? [], lang: lang)
    }

    fileprivate static func bestLogo(_ logos: [RawDetails.Images.Logo], lang: String) -> String? {
        func rank(_ l: RawDetails.Images.Logo) -> Int { l.iso6391 == lang ? 2 : (l.iso6391 == "en" ? 1 : 0) }
        return logos.filter { $0.filePath.hasSuffix(".png") }
            .sorted { rank($0) != rank($1) ? rank($0) > rank($1) : ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
            .first?.filePath
    }

    func details(_ ref: MediaRef) async throws -> TitleDetails {
        let lang = String(language.prefix(2))
        let extra = ref.type == .movie
            ? "credits,videos,recommendations,release_dates,images"
            : "credits,videos,recommendations,content_ratings,images"
        let d: RawDetails = try await fetch("/\(ref.type.rawValue)/\(ref.id)",
                                            ["append_to_response": extra, "include_image_language": "\(lang),en,null"])
        if let kids {
            let rating = ref.type == .movie ? Self.movieRating(d.releaseDates) : Self.tvRating(d.contentRatings)
            KidsFilter.shared.record(ref, rating: rating)
            guard d.adult != true, kids.genresAllowed((d.genres ?? []).map(\.id)), kids.allows(rating) else { throw Failure.blocked }
        }
        let date = (d.releaseDate?.isEmpty == false) ? d.releaseDate : d.firstAirDate
        let item = MediaItem(id: d.id, type: ref.type, title: d.title ?? d.name ?? "", overview: d.overview ?? "",
                             posterPath: d.posterPath, backdropPath: d.backdropPath,
                             voteAverage: d.voteAverage ?? 0, voteCount: d.voteCount ?? 0, date: date,
                             genreIDs: (d.genres ?? []).map(\.id))

        let videos = (d.videos?.results ?? []).filter { $0.site == "YouTube" }
        let trailer = videos.first { $0.type == "Trailer" && $0.official == true }
            ?? videos.first { $0.type == "Trailer" } ?? videos.first

        let country = region.isEmpty ? "US" : region
        var cert: String?
        if ref.type == .movie {
            let list = d.releaseDates?.results ?? []
            let match = list.first { $0.iso31661 == country } ?? list.first { $0.iso31661 == "US" }
            cert = match?.releaseDates.compactMap(\.certification).first { !$0.isEmpty }
        } else {
            let list = d.contentRatings?.results ?? []
            cert = (list.first { $0.iso31661 == country } ?? list.first { $0.iso31661 == "US" })?.rating
        }

        var credit: String?
        if let creators = d.createdBy, !creators.isEmpty {
            credit = "Created by " + creators.map(\.name).joined(separator: ", ")
        } else {
            let directors = (d.credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name)
            if !directors.isEmpty { credit = "Directed by " + directors.joined(separator: ", ") }
        }

        return TitleDetails(
            item: item,
            tagline: (d.tagline?.isEmpty == false) ? d.tagline : nil,
            runtime: d.runtime ?? d.episodeRunTime?.first,
            numberOfSeasons: d.numberOfSeasons ?? 0,
            seasons: (d.seasons ?? []).filter { $0.seasonNumber > 0 && $0.episodeCount > 0 },
            genres: d.genres ?? [],
            cast: Array((d.credits?.cast ?? []).prefix(20)),
            credit: credit,
            trailerKey: trailer?.key,
            recommendations: await limited(playable(d.recommendations?.results ?? [], ref.type).filter { $0.posterPath != nil }),
            certification: (cert?.isEmpty == false) ? cert : nil,
            logoPath: Self.bestLogo(d.images?.logos ?? [], lang: lang)
        )
    }

    /// Titles like this one: TMDB's recommendations, or its similar titles when there are none.
    func recommendations(_ ref: MediaRef) async -> [MediaItem] {
        let key = "\(ref.key)|\(kids?.maxRating.code ?? "-")"
        if let cached = RecommendationCache.shared.get(key) { return cached }
        var items: [MediaItem] = []
        for kind in ["recommendations", "similar"] {
            guard let p: RawPage = try? await fetch("/\(ref.type.rawValue)/\(ref.id)/\(kind)") else { continue }
            items = await limited(playable(p.results, ref.type).filter { $0.posterPath != nil })
            if !items.isEmpty { break }
        }
        if !Task.isCancelled { RecommendationCache.shared.set(key, items) }     // a row scrolled away mid-load must not cache an empty list
        return items
    }

    /// The episode after (season, episode), crossing into the next season. Only aired episodes.
    func nextEpisode(showID: Int, season: Int, episode: Int) async -> (season: Int, episode: Episode)? {
        guard let eps = try? await self.season(showID, season) else { return nil }
        let aired = eps.filter(\.aired)
        if let i = aired.firstIndex(where: { $0.episodeNumber == episode }), i + 1 < aired.count {
            return (season, aired[i + 1])
        }
        guard let d = try? await details(MediaRef(type: .tv, id: showID)),
              let next = d.seasons.first(where: { $0.seasonNumber > season }),
              let first = (try? await self.season(showID, next.seasonNumber))?.first(where: \.aired)
        else { return nil }
        return (next.seasonNumber, first)
    }
}

import Foundation
import Observation

/// The US maturity levels a kids profile can allow. The server stores them as "G", "PG", "PG-13" or "R".
nonisolated enum MaturityRating: Int, CaseIterable, Comparable, Sendable {
    case g, pg, pg13, r
    /// Above every allowed level (NC-17): never shown to a kids profile.
    case adultsOnly

    /// The levels a parent can pick for a kids profile.
    static let selectable: [MaturityRating] = [.g, .pg, .pg13]

    static func < (a: MaturityRating, b: MaturityRating) -> Bool { a.rawValue < b.rawValue }

    /// The server's maxRating value.
    init?(code: String?) {
        switch code {
        case "G": self = .g
        case "PG": self = .pg
        case "PG-13": self = .pg13
        case "R": self = .r
        default: return nil
        }
    }

    var code: String {
        switch self {
        case .g: "G"
        case .pg: "PG"
        case .pg13: "PG-13"
        case .r, .adultsOnly: "R"
        }
    }

    /// A US movie certification. Unrated and unknown values give nil.
    init?(movieCertification value: String?) {
        switch value?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "G": self = .g
        case "PG": self = .pg
        case "PG-13": self = .pg13
        case "R": self = .r
        case "NC-17": self = .adultsOnly
        default: return nil
        }
    }

    /// A US TV content rating mapped to the movie scale. Unrated and unknown values give nil.
    init?(tvRating value: String?) {
        switch value?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G": self = .g
        case "TV-PG": self = .pg
        case "TV-14": self = .pg13
        case "TV-MA": self = .r
        default: return nil
        }
    }

    /// The strictest rating in a list, so a title with several releases is judged by its most mature one. Unknown entries are ignored.
    static func strictest(_ ratings: [MaturityRating?]) -> MaturityRating? { ratings.compactMap { $0 }.max() }
}

/// What a kids profile is allowed to see. Built from the profile's server fields; nil means no restriction.
nonisolated struct KidsPolicy: Hashable, Sendable {
    var maxRating: MaturityRating

    /// TMDB genre ids that make up the kid-safe catalogue.
    enum Genre {
        static let animation = 16
        static let family = 10751
        static let kids = 10762
    }

    /// Genres that mostly hold adult titles. Used only to skip a rating lookup for results that would be blocked anyway.
    private static let adultSkewing: Set<Int> = [27, 53, 80, 10752, 10764, 10766, 10767, 10768]

    func allows(_ rating: MaturityRating?) -> Bool {
        guard let rating else { return false }                // unrated or unknown is blocked
        return rating <= maxRating
    }

    func genresAllowed(_ ids: [Int]) -> Bool { Set(ids).isDisjoint(with: Self.adultSkewing) }

    /// Discover parameters with the kid-safe limits added. The caller's own filters stay; the age limit cannot be removed.
    func discover(_ type: MediaType, _ params: [String: String]) -> [String: String] {
        var p = params
        p["include_adult"] = "false"
        if type == .movie {
            p["certification_country"] = "US"
            p["certification.lte"] = maxRating.code
            if p["with_genres"] == nil, p["with_cast"] == nil {
                p["with_genres"] = [Genre.animation, Genre.family].map(String.init).joined(separator: "|")
            }
        } else if p["with_genres"] == nil {
            p["with_genres"] = [Genre.kids, Genre.animation, Genre.family].map(String.init).joined(separator: "|")
        }
        return p
    }
}

extension SyncProfile {
    /// nil for a normal profile.
    var kidsPolicy: KidsPolicy? { kids ? KidsPolicy(maxRating: MaturityRating(code: maxRating) ?? .pg) : nil }
}

/// The outcome of looking up a title's US rating.
nonisolated enum RatingLookup: Sendable {
    case failed                          // the request failed: ask again later
    case found(MaturityRating?)          // nil = the title has no US rating
}

/// Which Continue Watching titles a kids profile may still resume. Kept up to date by the root view; nothing is allowed until checked.
@Observable
final class KidsVisibility {
    private(set) var allowed: Set<MediaRef> = []

    func refresh(_ refs: [MediaRef], policy: KidsPolicy?, tmdb: TMDB) async {
        guard let policy else { allowed = []; return }
        let result = await KidsFilter.shared.allowed(refs, policy: policy, tmdb: tmdb)
        if !Task.isCancelled { allowed = result }
    }
}

/// The one place that decides whether a title is suitable for a kids profile. Ratings are looked up once per title and remembered
/// for the session (on the main actor, like the catalog client). A lookup that fails counts as blocked, so a network error never lets a title through.
final class KidsFilter {
    static let shared = KidsFilter()

    private var ratings: [MediaRef: MaturityRating?] = [:]
    /// Rating lookups sent per call, so one search cannot send dozens of requests.
    private static let maxLookups = 60

    /// Remembers a rating that came with a title's own details.
    func record(_ ref: MediaRef, rating: MaturityRating?) { ratings[ref] = .some(rating) }

    func isKidSafe(_ ref: MediaRef, genres: [Int] = [], policy: KidsPolicy, tmdb: TMDB) async -> Bool {
        guard policy.genresAllowed(genres) else { return false }
        await load([ref], tmdb: tmdb)
        return policy.allows(ratings[ref] ?? nil)
    }

    /// Keeps the items that pass, in order. Results whose genres rule them out are dropped before any lookup.
    func filter(_ items: [MediaItem], policy: KidsPolicy, tmdb: TMDB) async -> [MediaItem] {
        let candidates = items.filter { policy.genresAllowed($0.genreIDs) }
        await load(candidates.map(\.ref), tmdb: tmdb)
        return candidates.filter { policy.allows(ratings[$0.ref] ?? nil) }
    }

    /// The refs that pass, for lists that have no genres to look at (Continue Watching).
    func allowed(_ refs: [MediaRef], policy: KidsPolicy, tmdb: TMDB) async -> Set<MediaRef> {
        await load(refs, tmdb: tmdb)
        return Set(refs.filter { policy.allows(ratings[$0] ?? nil) })
    }

    private func load(_ refs: [MediaRef], tmdb: TMDB) async {
        let missing = refs.filter { ratings[$0] == nil }.prefix(Self.maxLookups)
        guard !missing.isEmpty else { return }
        let results = await withTaskGroup(of: (MediaRef, RatingLookup).self) { group in
            for ref in missing { group.addTask { (ref, await tmdb.usRating(ref)) } }
            var out: [(MediaRef, RatingLookup)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (ref, lookup) in results {
            if case .found(let rating) = lookup { ratings[ref] = .some(rating) }   // a failed lookup is not remembered, so it is retried
        }
    }
}

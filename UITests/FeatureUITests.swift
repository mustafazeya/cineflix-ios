import XCTest

/// Talks to the two stand-in servers the feature tests need. Start them first:
///   node scripts/ui-test-servers/mock-sync.js   (port 8150)
///   node scripts/ui-test-servers/mock-tmdb.js   (port 8151)
enum Mock {
    static let sync = "http://127.0.0.1:8150"
    static let tmdb = "http://127.0.0.1:8151"
    static let page = "http://127.0.0.1:8161"

    private final class Box: @unchecked Sendable { var value: Any? }

    @discardableResult
    static func call(_ method: String, _ url: String, _ body: [String: Any]? = nil) -> Any? {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            box.value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            done.signal()
        }.resume()
        done.wait()
        return box.value
    }

    static func reset() {
        call("POST", sync + "/_test/reset")
        call("POST", tmdb + "/_test/clear")
    }

    static func profiles(_ email: String) -> [[String: Any]] {
        let state = call("GET", sync + "/_test/state?email=" + email) as? [String: Any]
        return (state?["profiles"] as? [[String: Any]]) ?? []
    }

    static func profileID(_ email: String, _ name: String) -> String {
        (profiles(email).first { $0["name"] as? String == name }?["id"] as? String) ?? ""
    }

    @discardableResult
    static func addProfile(_ email: String, name: String, kids: Bool = false, maxRating: String? = nil, pin: String? = nil) -> String {
        var body: [String: Any] = ["email": email, "name": name, "kids": kids]
        if let maxRating { body["maxRating"] = maxRating }
        if let pin { body["pin"] = pin }
        return ((call("POST", sync + "/_test/profile", body) as? [String: Any])?["id"] as? String) ?? ""
    }

    static func seed(_ email: String, _ profileID: String, _ changes: [[String: Any]]) {
        call("POST", sync + "/_test/seed", ["email": email, "profileId": profileID, "changes": changes])
    }

    /// What the app has pushed for one item (including tombstones), or nil.
    static func item(_ email: String, _ profileName: String, _ kind: String, _ key: String) -> [String: Any]? {
        let p = profiles(email).first { $0["name"] as? String == profileName }
        return (p?["items"] as? [[String: Any]])?.first { $0["kind"] as? String == kind && $0["key"] as? String == key }
    }

    /// What the stand-in player page's server saw for media requests (mock-page.js).
    static func pageLog() -> [[String: Any]] { (call("GET", page + "/_test/log") as? [[String: Any]]) ?? [] }

    static func video(_ id: String, name: String, url: String) -> [String: Any] {
        let now = Date().timeIntervalSince1970 * 1000
        return ["kind": "video", "key": id, "updatedAt": now, "value": ["id": id, "name": name, "url": url, "addedAt": now]]
    }

    static func resume(_ key: String, position: Double, duration: Double, title: String, age: Double = 0) -> [String: Any] {
        let at = (Date().timeIntervalSince1970 - age) * 1000
        return ["kind": "resume", "key": key, "updatedAt": at,
                "value": ["key": key, "position": position, "duration": duration, "title": title, "updatedAt": at]]
    }

    static func tmdbLog() -> [String] { (call("GET", tmdb + "/_test/log") as? [String]) ?? [] }

    static func progress(_ type: String, _ id: Int, title: String, position: Double = 600, season: Int? = nil, episode: Int? = nil, age: Double = 0) -> [String: Any] {
        var v: [String: Any] = ["type": type, "id": id, "position": position, "duration": 5400, "title": title,
                                "backdrop_path": "/b\(id).jpg", "poster_path": "/p\(id).jpg",
                                "updatedAt": (Date().timeIntervalSince1970 - age) * 1000, "finished": false]
        if let season { v["season"] = season }
        if let episode { v["episode"] = episode }
        return ["kind": "progress", "key": "\(type):\(id)", "value": v, "updatedAt": v["updatedAt"]!]
    }

    static func watched(_ id: Int, title: String) -> [String: Any] {
        let now = Date().timeIntervalSince1970 * 1000
        return ["kind": "watched", "key": "movie:\(id)", "updatedAt": now,
                "value": ["id": id, "media_type": "movie", "title": title, "poster_path": "/p\(id).jpg", "backdrop_path": "/b\(id).jpg", "genre_ids": [16], "watchedAt": now]]
    }

    static func listItem(_ id: Int, title: String) -> [String: Any] {
        let now = Date().timeIntervalSince1970 * 1000
        return ["kind": "list", "key": "movie:\(id)", "updatedAt": now,
                "value": ["id": id, "media_type": "movie", "title": title, "poster_path": "/p\(id).jpg", "backdrop_path": "/b\(id).jpg", "addedAt": now]]
    }

    static func rating(_ id: Int, title: String, _ value: Int) -> [String: Any] {
        let now = Date().timeIntervalSince1970 * 1000
        return ["kind": "rating", "key": "movie:\(id)", "updatedAt": now,
                "value": ["id": id, "media_type": "movie", "title": title, "poster_path": "/p\(id).jpg", "backdrop_path": "/b\(id).jpg",
                          "genre_ids": [16], "rating": value, "ratedAt": now]]
    }
}

/// Shared set-up: the app talks to the stand-in sync server and TMDB, and starts as a guest.
class FeatureTestCase: XCTestCase {
    var app: XCUIApplication!
    var email = ""
    /// Subclasses that need the real TMDB (token from Config/Secrets.xcconfig) turn this off.
    class var usesMockTMDB: Bool { true }
    class var extraArguments: [String] { [] }

    override func setUp() {
        continueAfterFailure = false
        Mock.reset()
        app = XCUIApplication()
        app.launchArguments += ["-cf.noCast", "YES", "-cf.resetLibrary", "YES", "-cf.syncServer", Mock.sync]
        app.launchArguments += Self.extraArguments
        if Self.usesMockTMDB { app.launchArguments += ["-cf.tmdbBase", Mock.tmdb + "/3", "-cf.tmdbToken", "test"] }
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func eventually(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    /// Creates an account on the stand-in server through the app and stops at the profile picker.
    func signUp() {
        email = "feature-\(Int(Date().timeIntervalSince1970))@example.com"
        app.tabBars.buttons["My Stuff"].tap()
        let guest = app.buttons["guest-card"]
        XCTAssertTrue(guest.waitForExistence(timeout: 30), "guest card visible")
        guest.tap()
        let field = app.textFields["signin-email"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["New here? Create an account"].tap()
        field.tap()
        field.typeText(email)
        let pw = app.secureTextFields["signin-password"]
        pw.tap()
        pw.typeText("correct horse battery")
        app.buttons["signin-submit"].tap()
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 30), "picker after sign-up")
    }

    var defaultProfileName: String { String(email.split(separator: "@")[0]) }

    /// Creates an account with these profiles on the stand-in server and signs in with it. Returns the profile ids by name.
    @discardableResult
    func signIn(profiles: [[String: Any]]) -> [String: String] {
        email = "feature-\(Int(Date().timeIntervalSince1970))@example.com"
        let ids = (Mock.call("POST", Mock.sync + "/_test/account", ["email": email, "profiles": profiles]) as? [String: String]) ?? [:]
        app.tabBars.buttons["My Stuff"].tap()
        let guest = app.buttons["guest-card"]
        XCTAssertTrue(guest.waitForExistence(timeout: 30), "guest card visible")
        guest.tap()
        let field = app.textFields["signin-email"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(email)
        let pw = app.secureTextFields["signin-password"]
        pw.tap()
        pw.typeText("correct horse battery")
        app.buttons["signin-submit"].tap()
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 30), "picker after sign-in")
        return ids
    }

    func choose(_ name: String) {
        let tile = app.buttons["profile-\(name)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "profile \(name) listed")
        tile.tap()
    }

    func typePin(_ pin: String, field: String = "pin-field") {
        let f = app.secureTextFields[field]
        XCTAssertTrue(f.waitForExistence(timeout: 10), "PIN field shown")
        f.tap()
        f.typeText(pin)
    }

    /// Waits for the profile picker to close, then opens Home.
    func goHome() {
        let picker = app.staticTexts["Who's watching?"]
        XCTAssertTrue(eventually(20) { !picker.exists }, "picker closed")
        app.tabBars.buttons["Home"].tap()
    }

    func openMyStuff() {
        if app.keyboards.count > 0, app.buttons["Close"].exists { app.buttons["Close"].firstMatch.tap() }      // leave the search field first
        let tab = app.tabBars.buttons["My Stuff"]
        tab.tap()
        if !tab.isSelected { tab.tap() }
    }

    func openTitle(_ search: String, _ label: String) {
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(search)
        let result = app.buttons[label].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "search finds \(label)")
        result.tap()
    }

    /// Scrolls down in short steps, so rows that load as they come into view get time to finish.
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var n = 0
        while !element.exists && n < maxSwipes * 3 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            _ = element.waitForExistence(timeout: 1.5)
            n += 1
        }
        XCTAssertTrue(element.exists, "\(element) found after scrolling")
    }
}

/// Mark watched / remove from Continue Watching, and single episodes.
final class WatchedUITests: FeatureTestCase {
    @MainActor func testContinueWatchingMenu() throws {
        signUp()
        let id = Mock.profileID(email, defaultProfileName)
        Mock.seed(email, id, [Mock.progress("movie", 9001, title: "Pip the Penguin"),
                              Mock.progress("movie", 9002, title: "Robo Pals", age: 10),
                              Mock.progress("tv", 8001, title: "Kikis Club", season: 1, episode: 2, age: 20)])
        choose(defaultProfileName)
        goHome()

        // Home: the long-press menu removes an entry without marking it watched.
        let pip = app.buttons["continue-movie:9001"]
        scrollTo(pip, maxSwipes: 2)
        pip.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Mark as watched"].waitForExistence(timeout: 5), "menu has Mark as watched")
        XCTAssertTrue(app.buttons["Remove from Continue Watching"].exists, "menu has Remove")
        shot("w01-menu")
        app.buttons["Remove from Continue Watching"].tap()
        XCTAssertTrue(eventually(5) { !pip.exists }, "card removed")
        XCTAssertTrue(eventually(30) { Mock.item(email, defaultProfileName, "progress", "movie:9001")?["deleted"] as? Bool == true }, "progress tombstone synced")
        XCTAssertNil(Mock.item(email, defaultProfileName, "watched", "movie:9001"), "removing does not mark it watched")

        // My Stuff shows the same row and menu: Mark as watched.
        openMyStuff()
        let robo = app.buttons["mystuff-continue-movie:9002"]
        XCTAssertTrue(robo.waitForExistence(timeout: 10))
        robo.press(forDuration: 1.0)
        app.buttons["Mark as watched"].tap()
        XCTAssertTrue(eventually(5) { !robo.exists }, "card removed")
        XCTAssertTrue(eventually(30) {
            Mock.item(email, defaultProfileName, "watched", "movie:9002")?["deleted"] as? Bool == false
                && Mock.item(email, defaultProfileName, "progress", "movie:9002")?["deleted"] as? Bool == true
        }, "watched item pushed and progress tombstoned")
        app.buttons["Watched"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Robo Pals"].waitForExistence(timeout: 5), "listed under Watched")
        shot("w02-watched")
    }

    @MainActor func testEpisodeToggle() throws {
        signUp()
        let id = Mock.profileID(email, defaultProfileName)
        Mock.seed(email, id, [Mock.progress("tv", 8001, title: "Kikis Club", season: 1, episode: 2)])
        choose(defaultProfileName)
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 15))

        openTitle("Kikis", "Kikis Club")
        let check = app.buttons["episode-watched-2"]
        scrollTo(check)
        XCTAssertEqual(check.value as? String, "Not watched")
        check.tap()
        XCTAssertEqual(check.value as? String, "Watched")
        shot("w03-episode-watched")
        XCTAssertTrue(eventually(30) { Mock.item(email, defaultProfileName, "episode", "tv:8001:1:2")?["deleted"] as? Bool == false }, "episode synced")
        let p = Mock.item(email, "Mum", "progress", "tv:8001")?["value"] as? [String: Any]
        XCTAssertEqual(p?["finished"] as? Bool, true, "Continue Watching follows: the saved episode is finished")

        check.tap()
        XCTAssertEqual(check.value as? String, "Not watched")
        XCTAssertTrue(eventually(30) { Mock.item(email, defaultProfileName, "episode", "tv:8001:1:2")?["deleted"] as? Bool == true }, "tombstone synced")

        // The long-press menu does the same for another episode.
        let row = app.buttons["episode-3"]
        scrollTo(row)
        row.press(forDuration: 1.0)
        app.buttons["Mark as watched"].tap()
        XCTAssertEqual(app.buttons["episode-watched-3"].value as? String, "Watched")
        XCTAssertTrue(eventually(30) { Mock.item(email, defaultProfileName, "episode", "tv:8001:1:3")?["deleted"] as? Bool == false })
    }
}

/// Thumbs up/down on the title page and the "Because you watched" rows on Home.
final class RatingsUITests: FeatureTestCase {
    @MainActor func testThumbsAndBecauseYouWatched() throws {
        signUp()
        let id = Mock.profileID(email, defaultProfileName)
        // Garden Gnomes was thumbed down, Dragon Academy watched.
        Mock.seed(email, id, [Mock.rating(9003, title: "Garden Gnomes", -1), Mock.watched(9004, title: "Dragon Academy")])
        choose(defaultProfileName)
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 15))

        openTitle("Pip", "Pip the Penguin")
        let up = app.buttons["thumbs-up"], down = app.buttons["thumbs-down"]
        XCTAssertTrue(up.waitForExistence(timeout: 15))
        up.tap()
        XCTAssertEqual(up.value as? String, "Selected")
        shot("r01-thumbs")
        XCTAssertTrue(eventually(30) { Mock.item(email, defaultProfileName, "rating", "movie:9001")?["deleted"] as? Bool == false }, "rating synced")
        let v = Mock.item(email, defaultProfileName, "rating", "movie:9001")?["value"] as? [String: Any]
        XCTAssertEqual(v?["rating"] as? Int, 1)
        XCTAssertEqual(v?["media_type"] as? String, "movie")
        XCTAssertEqual(v?["title"] as? String, "Pip the Penguin")
        XCTAssertEqual(v?["genre_ids"] as? [Int], [16, 10751])
        XCTAssertNotNil(v?["poster_path"]); XCTAssertNotNil(v?["backdrop_path"]); XCTAssertNotNil(v?["ratedAt"])

        up.tap()
        XCTAssertEqual(up.value as? String, "")
        XCTAssertTrue(eventually(30) { Mock.item(email, defaultProfileName, "rating", "movie:9001")?["deleted"] as? Bool == true }, "tap again clears (tombstone)")
        down.tap()
        XCTAssertEqual(down.value as? String, "Selected")
        up.tap()
        XCTAssertEqual(down.value as? String, "", "thumbs are exclusive")
        XCTAssertEqual(up.value as? String, "Selected")

        // Home: Pip (thumbs up) first, then Dragon Academy (watched).
        app.tabBars.buttons["Home"].tap()
        let first = app.staticTexts["Because you watched Pip the Penguin"]
        scrollTo(first, maxSwipes: 10)
        let row = app.otherElements["because-movie:9001"]
        XCTAssertTrue(row.buttons["Robo Pals"].waitForExistence(timeout: 15), "recommendations listed")
        XCTAssertFalse(row.buttons["Garden Gnomes"].exists, "thumbed-down title left out")
        XCTAssertFalse(row.buttons["Dragon Academy"].exists, "watched title left out")
        XCTAssertFalse(row.buttons["Pip the Penguin"].exists, "the seed itself is left out")
        shot("r02-because")
        XCTAssertTrue(app.staticTexts["Because you watched Dragon Academy"].exists || { app.swipeUp(); return app.staticTexts["Because you watched Dragon Academy"].waitForExistence(timeout: 10) }(), "second row")
        XCTAssertFalse(app.staticTexts["Because you watched Garden Gnomes"].exists, "no row for a thumbed-down title")
    }
}

/// Kids profiles: filter, PIN gate, badges and the profile editor.
final class KidsUITests: FeatureTestCase {
    /// Titles in the mock catalogue that a PG profile must never see: R, unrated, mixed PG/R, PG-13, TV-MA and unrated series.
    static let blockedForJunior = ["Night Hollow", "Cold Case Files", "Mystery Reel", "Double Feature", "Grim Streets", "Toon Nights",
                                   "Wild Action", "Midnight Heist", "Mystery Show", "Teen Drama High", "Sunny Days"]

    @MainActor func testKidsFilterAndPinGate() throws {
        let ids = signIn(profiles: [["name": "Mum"], ["name": "Junior", "kids": true, "maxRating": "PG", "pin": "1234"],
                                    ["name": "Tiny", "kids": true, "maxRating": "G"], ["name": "Dad", "pin": "4321"]])
        // Left over from before the limit was set: an R title in Continue Watching and in My List.
        Mock.seed(email, ids["Junior"] ?? "", [Mock.progress("movie", 9005, title: "Night Hollow"), Mock.listItem(9005, title: "Night Hollow"),
                                               Mock.progress("movie", 9001, title: "Pip the Penguin", age: 5)])

        // Picker: badges and lock glyphs.
        XCTAssertTrue(app.buttons["profile-Junior"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["profile-Junior"].value as? String, "Kids, PIN protected")
        XCTAssertEqual(app.buttons["profile-Tiny"].value as? String, "Kids")
        XCTAssertEqual(app.buttons["profile-Dad"].value as? String, "PIN protected")
        shot("k01-picker")

        // A PIN-protected adult profile asks for its PIN: wrong first, then right.
        choose("Dad")
        typePin("0000")
        app.buttons["pin-submit"].tap()
        XCTAssertTrue(app.staticTexts["pin-error"].waitForExistence(timeout: 10), "wrong PIN is reported")
        XCTAssertEqual(app.staticTexts["pin-error"].label, "That PIN is not right")
        shot("k02-bad-pin")
        typePin("4321")
        app.buttons["pin-submit"].tap()
        goHome()
        XCTAssertTrue(app.staticTexts["Top 10 Today"].waitForExistence(timeout: 20), "adult home")

        // Switch to the kids profile: opens without a PIN.
        openMyStuff()
        app.buttons["account-menu"].tap()
        app.buttons["Switch profile"].tap()
        choose("Junior")
        XCTAssertTrue(app.buttons["account-menu"].waitForExistence(timeout: 15))
        Mock.call("POST", Mock.tmdb + "/_test/clear")

        // Kids Home: kid-safe rows only, and a Videos tab is not offered.
        goHome()
        let popular = app.staticTexts["Popular Movies"]
        scrollTo(popular)
        XCTAssertFalse(app.staticTexts["Top 10 Today"].exists, "no adult rows")
        XCTAssertTrue(app.buttons["Pip the Penguin"].firstMatch.waitForExistence(timeout: 15), "a G title is shown")
        for _ in 0..<10 {      // visit the other rows, so they load and can be checked
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            Thread.sleep(forTimeInterval: 0.7)
            for blocked in Self.blockedForJunior { XCTAssertFalse(app.buttons[blocked].exists, "\(blocked) is not shown to Junior") }
        }
        XCTAssertTrue(app.staticTexts["Kids TV"].exists || app.staticTexts["Top Rated Movies"].exists, "reached the lower rows")
        shot("k03-kids-home")
        let log = Mock.tmdbLog()
        let movieDiscover = log.filter { $0.contains("/discover/movie") }
        XCTAssertFalse(movieDiscover.isEmpty)
        XCTAssertTrue(movieDiscover.allSatisfy { $0.contains("certification.lte=PG") && $0.contains("certification_country=US") }, "movie rows use the age limit")
        XCTAssertTrue(log.filter { $0.contains("/discover/") }.allSatisfy { $0.contains("include_adult=false") }, "adult content excluded")
        XCTAssertTrue(log.contains { $0.contains("/release_dates") }, "ratings looked up")
        XCTAssertFalse(log.contains { $0.contains("/trending/") }, "no trending list for kids")

        // Search: every result must pass the check.
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Space")
        XCTAssertTrue(app.buttons["Space Pups"].waitForExistence(timeout: 15), "PG title found")
        field.clearAndType("Night")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 15), "R title hidden")
        field.clearAndType("Double")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 15), "mixed PG/R release counts as R")
        field.clearAndType("Mystery")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 15), "unrated movie and series hidden")
        field.clearAndType("Wild")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 15), "PG-13 hidden from a PG profile")
        shot("k04-search")

        // Continue Watching only lists what still passes; the R title is hidden, the G title can be resumed.
        openMyStuff()
        XCTAssertTrue(app.buttons["mystuff-continue-movie:9001"].waitForExistence(timeout: 10), "allowed title in Continue Watching")
        XCTAssertFalse(app.buttons["mystuff-continue-movie:9005"].exists, "blocked title hidden from Continue Watching")
        // Opening a blocked title (a stale My List entry) is refused.
        let stale = app.buttons["Night Hollow"].firstMatch
        XCTAssertTrue(stale.waitForExistence(timeout: 10))
        stale.tap()
        XCTAssertTrue(app.staticTexts["Not available on this profile"].waitForExistence(timeout: 15), "blocked title page")
        shot("k05-blocked")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(app.buttons["Videos"].exists, "My Videos is hidden in a kids profile")

        // Leaving the kids profile needs its PIN: Cancel, wrong PIN, right PIN.
        app.buttons["account-menu"].tap()
        app.buttons["Switch profile"].tap()
        XCTAssertTrue(app.secureTextFields["pin-field"].waitForExistence(timeout: 10), "PIN asked before switching")
        shot("k06-leave-pin")
        app.buttons["pin-cancel"].tap()
        XCTAssertFalse(app.staticTexts["Who's watching?"].exists, "still in the kids profile")
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.secureTextFields["pin-field"].waitForExistence(timeout: 10), "PIN asked before Settings")
        typePin("1111")
        app.buttons["pin-submit"].tap()
        XCTAssertTrue(app.staticTexts["pin-error"].waitForExistence(timeout: 10))
        app.buttons["pin-cancel"].tap()
        app.buttons["account-menu"].tap()
        app.buttons["Sign out"].tap()
        typePin("1234")
        app.buttons["pin-submit"].tap()
        XCTAssertTrue(app.buttons["Sign out"].waitForExistence(timeout: 10), "confirmation after the PIN")
        app.buttons["Sign out"].tap()
        XCTAssertTrue(app.buttons["guest-card"].waitForExistence(timeout: 15), "signed out after the PIN")
    }

    @MainActor func testKidsProfileWithoutPinLeavesFreely() throws {
        signIn(profiles: [["name": "Mum"], ["name": "Tiny", "kids": true, "maxRating": "G"]])
        choose("Tiny")
        openMyStuff()
        app.buttons["account-menu"].tap()
        app.buttons["Switch profile"].tap()
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 10), "no PIN asked")
        XCTAssertFalse(app.secureTextFields["pin-field"].exists)
    }

    @MainActor func testProfileEditorKidsAndPin() throws {
        signIn(profiles: [["name": "Mum"]])
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'manage profiles'")).firstMatch.tap()
        app.buttons["profile-add"].tap()
        let name = app.textFields["profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Mini")
        app.switches["kids-toggle"].tap()
        XCTAssertTrue(app.segmentedControls["max-rating"].waitForExistence(timeout: 5), "rating choice appears")
        app.segmentedControls["max-rating"].buttons["PG-13"].tap()
        let pin = app.secureTextFields["pin-new"]
        pin.tap()
        pin.typeText("2468")
        let again = app.secureTextFields["pin-repeat"]
        again.tap()
        again.typeText("2468")
        shot("e01-editor")
        app.buttons["profile-save"].tap()
        XCTAssertTrue(eventually(15) { Mock.profiles(self.email).contains { $0["name"] as? String == "Mini" } }, "created")
        let mini = Mock.profiles(email).first { $0["name"] as? String == "Mini" }
        XCTAssertEqual(mini?["kids"] as? Bool, true)
        XCTAssertEqual(mini?["maxRating"] as? String, "PG-13")
        XCTAssertEqual(mini?["hasPin"] as? Bool, true)

        // Editing a protected profile asks for its PIN first; then the PIN can be removed.
        let tile = app.buttons["profile-Mini"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        typePin("2468")
        app.buttons["pin-submit"].tap()
        XCTAssertTrue(app.buttons["pin-remove"].waitForExistence(timeout: 10), "editor opens after the PIN")
        app.buttons["pin-remove"].tap()
        app.buttons["profile-save"].tap()
        XCTAssertTrue(eventually(15) { (Mock.profiles(self.email).first { $0["name"] as? String == "Mini" }?["hasPin"] as? Bool) == false }, "PIN removed")
    }
}

extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty, current != "Movies, shows" {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}

/// The kids filter against the real TMDB: ratings come from the live release_dates and content_ratings data.
final class KidsRealTMDBUITests: FeatureTestCase {
    override class var usesMockTMDB: Bool { false }

    @MainActor func testSearchIsFilteredByRealRatings() throws {
        signIn(profiles: [["name": "Mum"], ["name": "Junior", "kids": true, "maxRating": "PG"]])
        choose("Junior")
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 20))
        goHome()
        let home = app.staticTexts["Popular Movies"]
        scrollTo(home)
        shot("t01-kids-home")

        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Toy Story")
        XCTAssertTrue(app.buttons["Toy Story"].firstMatch.waitForExistence(timeout: 30), "a G movie is found")
        shot("t02-toy-story")
        field.clearAndType("Deadpool")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 30), "an R movie is hidden")
        field.clearAndType("South Park")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 30), "a TV-MA series is hidden")
        field.clearAndType("Bluey")
        XCTAssertTrue(app.buttons["Bluey"].firstMatch.waitForExistence(timeout: 30), "a TV-Y series is found")
    }
}


/// The Netflix-style card near the end of an episode. Needs a media server that answers /tv/... with a short video:
///   node scripts/ui-test-servers/mock-media.js <video file>   (port 8160)
final class NextEpisodeUITests: FeatureTestCase {
    override class var extraArguments: [String] {
        ["-cf.streamBase", "http://127.0.0.1:8160", "-cf.streamType", "video", "-cf.nextLead", "11", "-cf.nextMinLength", "5"]
    }

    private func startEpisode(_ episode: Int) {
        let ids = signIn(profiles: [["name": "Mum"]])
        Mock.seed(email, ids["Mum"] ?? "", [Mock.progress("tv", 8001, title: "Kikis Club", position: 1, season: 1, episode: episode)])
        choose("Mum")
        // The first tap can land while the picker is still animating in.
        if !eventually(6, { !app.staticTexts["Who's watching?"].exists }) { app.buttons["profile-Mum"].tap() }
        goHome()
        let card = app.buttons["continue-tv:8001"]
        scrollTo(card, maxSwipes: 2)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["Subtitles"].waitForExistence(timeout: 20), "player opened")
    }

    @MainActor func testCardCountsDownAndPlaysNextEpisode() throws {
        startEpisode(1)
        let title = app.staticTexts["S1:E2  Episode 2 title"]
        XCTAssertTrue(title.waitForExistence(timeout: 40), "card names the next episode")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Next Episode'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Starting in'")).firstMatch.exists, "countdown shown")
        shot("n01-card")
        // The countdown ends by itself and episode 2 plays: its own card then names episode 3 (not 4, which would mean a skipped episode).
        XCTAssertTrue(app.staticTexts["S1:E3  Episode 3 title"].waitForExistence(timeout: 40), "episode 2 started after the countdown")
    }

    @MainActor func testPlayNowAndWatchCredits() throws {
        startEpisode(1)
        XCTAssertTrue(app.buttons["Play now"].waitForExistence(timeout: 40))
        app.buttons["Watch credits"].tap()
        XCTAssertTrue(eventually(3) { !app.buttons["Play now"].exists }, "card dismissed")
        // After the video ends the card comes back, without a countdown.
        XCTAssertTrue(app.buttons["Play now"].waitForExistence(timeout: 30), "static card after the end")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Starting in'")).firstMatch.exists, "no countdown")
        app.buttons["Play now"].tap()
        XCTAssertTrue(app.staticTexts["S1:E3  Episode 3 title"].waitForExistence(timeout: 40), "episode 2 started")
    }

    @MainActor func testButtonsFollowTheSystemControlsAndComeBackWithTheCard() throws {
        startEpisode(1)
        let subtitles = app.buttons["Subtitles"]
        let systemClose = app.buttons["Close"]
        XCTAssertTrue(eventually(12) { !subtitles.isHittable && !systemClose.exists }, "our buttons and the system's controls are both gone while playing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(eventually(3) { subtitles.isHittable && systemClose.exists }, "a tap brings both back")
        // They leave together, never one without the other.
        let end = Date().addingTimeInterval(12)
        var apart = false
        while Date() < end && (subtitles.isHittable || systemClose.exists) {
            if subtitles.isHittable != systemClose.exists { apart = true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(subtitles.isHittable || systemClose.exists, "both gone again")
        XCTAssertFalse(apart, "our buttons never stayed after the system controls left")
        // The next-episode card needs the viewer, so it brings our buttons back by itself.
        XCTAssertTrue(app.buttons["Play now"].waitForExistence(timeout: 30), "card shown")
        XCTAssertTrue(subtitles.isHittable, "buttons are back with the card")
    }

    @MainActor func testLastEpisodeHasNoCard() throws {
        startEpisode(4)
        sleep(14)
        XCTAssertFalse(app.buttons["Play now"].exists, "the last episode has no next card")
    }
}


/// Saved links remember where they were left, per profile, and sync it. Needs a video of about 400 seconds as "your media server":
///   node scripts/ui-test-servers/mock-media.js <video of about 400 s>   (port 8160, answers every path with that video)
final class ResumeUITests: FeatureTestCase {
    override class var extraArguments: [String] { ["-cf.testClock", "YES"] }

    private let link = "http://127.0.0.1:8160/clip.mp4"

    /// Signs in with one profile that has a saved link (and optionally a saved position) and opens My Videos.
    private func openVideos(_ extra: [[String: Any]] = []) {
        let ids = signIn(profiles: [["name": "Mum"]])
        Mock.seed(email, ids["Mum"] ?? "", [Mock.video("vclip1", name: "Clip", url: link)] + extra)
        choose("Mum")
        if !eventually(6, { !app.staticTexts["Who's watching?"].exists }) { app.buttons["profile-Mum"].tap() }
        goHome()
        openMyStuff()
        app.buttons["Videos"].firstMatch.tap()
        XCTAssertTrue(app.buttons["video-Clip"].waitForExistence(timeout: 20), "saved link listed")
    }

    private func clock() -> Int { Int(app.staticTexts["player-clock"].firstMatch.label) ?? -1 }

    @MainActor func testResumesFromSyncedPositionSavesAndStartsOver() throws {
        openVideos([Mock.resume("v:vclip1", position: 60, duration: 400, title: "Clip")])
        let row = app.buttons["video-Clip"]
        XCTAssertTrue(row.label.contains("Resume 1:00"), "row shows the synced position: \(row.label)")
        shot("r01-row")
        row.tap()
        XCTAssertTrue(playerOpened(), "player opened")
        XCTAssertTrue(eventually(30) { clock() >= 59 }, "playback starts at the synced position (clock \(clock()))")
        XCTAssertTrue(eventually(30) { clock() >= 72 }, "and plays on")
        showControls()
        app.buttons["Close"].tap()

        // The new position goes to the server, as the newest edit.
        XCTAssertTrue(eventually(40) { ((Mock.item(email, "Mum", "resume", "v:vclip1")?["value"] as? [String: Any])?["position"] as? Double ?? 0) >= 70 }, "new position pushed")
        let pushed = Mock.item(email, "Mum", "resume", "v:vclip1")?["value"] as? [String: Any]
        XCTAssertEqual(pushed?["title"] as? String, "Clip")
        XCTAssertEqual(pushed?["key"] as? String, "v:vclip1")
        XCTAssertGreaterThan(pushed?["duration"] as? Double ?? 0, 100)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(eventually(5) { row.label.contains("Resume 1:1") }, "row shows the new position: \(row.label)")
        shot("r02-after")

        // Start over deletes it everywhere.
        row.press(forDuration: 1.0)
        let start = app.buttons["Start over"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "context menu offers Start over")
        start.tap()
        XCTAssertTrue(eventually(5) { !row.label.contains("Resume") }, "label gone")
        XCTAssertTrue(eventually(40) { Mock.item(email, "Mum", "resume", "v:vclip1")?["deleted"] as? Bool == true }, "tombstone pushed")
    }

    @MainActor func testFinishedVideoDeletesItsPosition() throws {
        openVideos([Mock.resume("v:vclip1", position: 380, duration: 400, title: "Clip")])
        app.buttons["video-Clip"].tap()
        XCTAssertTrue(playerOpened(), "player opened")
        XCTAssertTrue(eventually(30) { clock() >= 379 }, "starts near the end")
        // The video ends, the player closes by itself and the entry is a tombstone, so the next play starts at 0.
        XCTAssertTrue(eventually(60) { Mock.item(email, "Mum", "resume", "v:vclip1")?["deleted"] as? Bool == true }, "finished entry deleted")
        XCTAssertTrue(app.buttons["video-Clip"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["video-Clip"].label.contains("Resume"))
    }

    @MainActor func testPositionUnderTenSecondsIsNotSaved() throws {
        openVideos()
        app.buttons["video-Clip"].tap()
        XCTAssertTrue(playerOpened())
        XCTAssertTrue(eventually(30) { clock() >= 4 })
        showControls()
        app.buttons["Close"].tap()
        sleep(10)
        XCTAssertNil(Mock.item(email, "Mum", "resume", "v:vclip1"), "nothing saved before 10 seconds")
    }
}

/// "Play natively" for a media server page that plays through a blob: address. Needs the stand-in page server:
///   node scripts/ui-test-servers/mock-page.js <video.mp4>   (port 8161)
/// AirPlay and Chromecast to a real receiver are not part of these tests; they cover finding the stream, handing it to AVPlayer with the
/// page's Referer and cookie, the position and the way back.
final class NativeSwitchUITests: FeatureTestCase {
    override class var extraArguments: [String] { ["-cf.testClock", "YES", "-cf.pageReveal", "4", "-cf.showPageNote", "YES"] }

    /// Saves a link to the mock server's page and opens it, like a title from the user's own server.
    private func openPage(_ via: String) {
        Mock.call("POST", Mock.page + "/_test/clear")
        app.tabBars.buttons["My Stuff"].tap()
        app.buttons["Videos"].firstMatch.tap()
        let add = app.buttons["video-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        add.tap()
        let name = app.textFields["video-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Page")
        let link = app.textFields["video-link"]
        link.tap()
        link.typeText("\(Mock.page)/page?via=\(via)")
        app.buttons["video-save"].tap()
        let row = app.buttons["video-Page"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "saved page listed")
        row.tap()
    }

    private func clock() -> Int { Int(app.staticTexts["player-clock"].firstMatch.label) ?? -1 }

    private func nativeRequests(_ path: String) -> [[String: Any]] {
        Mock.pageLog().filter { $0["path"] as? String == path && $0["native"] as? Bool == true }
    }

    private func assertNoExtraButtons() {
        XCTAssertFalse(app.buttons["play-natively"].exists, "no 'Play natively' button")
        XCTAssertFalse(app.buttons["back-to-page-top"].exists, "no 'Back to page' button")
    }

    /// Nothing to tap: the stream behind the page's blob: address is found and plays in the app's own player, with the page's Referer and cookie.
    @MainActor func testPageIsPlayedInTheAppsPlayerByItself() throws {
        openPage("mp4")
        XCTAssertTrue(eventually(40) { !self.nativeRequests("/media/clip.mp4").isEmpty }, "the app's player loaded the real stream address")
        let request = nativeRequests("/media/clip.mp4").first
        XCTAssertEqual(request?["ok"] as? Bool, true, "Referer and cookie of the page were sent: \(request ?? [:])")
        XCTAssertEqual(request?["referer"] as? String, "\(Mock.page)/page?via=mp4")
        XCTAssertTrue((request?["cookie"] as? String ?? "").contains("sid=test"))
        XCTAssertTrue(eventually(30) { clock() >= 3 }, "it plays (clock \(clock()))")
        shot("p01-native")
        assertNoExtraButtons()
        // One close button: the system player's, once the controls are up.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(eventually(3) { self.app.buttons["Close"].exists })
        XCTAssertEqual(app.buttons.matching(identifier: "Close").count + app.buttons.matching(NSPredicate(format: "label == 'Close' AND identifier != 'Close Button'")).count, 1, "a single close button")
        shot("p02-controls")
    }

    @MainActor func testHlsMasterIsPlayedAndAFailingStreamOffersThePagePlayer() throws {
        openPage("hls")
        // The master playlist is what gets played, not one of its qualities.
        XCTAssertTrue(eventually(40) { !self.nativeRequests("/hls/master.m3u8").isEmpty }, "the app's player asked for the master playlist")
        XCTAssertEqual(nativeRequests("/hls/master.m3u8").first?["ok"] as? Bool, true)
        // Its segments do not exist, so playing fails through the phone and then directly; the page's own player takes over by itself, with the reason.
        XCTAssertTrue(app.staticTexts["fallback-note"].waitForExistence(timeout: 100) || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Played in the page player'")).firstMatch.waitForExistence(timeout: 5), "page player took over and says why")
        shot("p03-fallback")
        let before = nativeRequests("/hls/master.m3u8").count
        sleep(6)
        XCTAssertEqual(nativeRequests("/hls/master.m3u8").count, before, "it does not switch back to the app's player again")
        XCTAssertTrue(app.buttons["Close"].exists, "the page player has a close button")
        assertNoExtraButtons()
    }

    /// A frame that appears after the page was shown (an ad or player iframe) is not silenced by the app: the page's sound is its own.
    @MainActor func testFrameCreatedAfterRevealIsNotMuted() throws {
        openPage("late")
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 25), "the page is shown")
        XCTAssertTrue(eventually(40) { !Mock.pageLog().filter { $0["path"] as? String == "/frame-state" }.isEmpty }, "the late frame loaded")
        sleep(3)
        let states = Mock.pageLog().filter { $0["path"] as? String == "/frame-state" }
        XCTAssertEqual(states.last?["muted"] as? Bool, false, "the late frame's video was left alone (\(states.suffix(3)))")
    }

    @MainActor func testStreamFoundThroughXHR() throws {
        openPage("xhr")
        XCTAssertTrue(eventually(40) { !self.nativeRequests("/media/clip.mp4").isEmpty })
    }

    @MainActor func testStreamFoundThroughHlsJsLoadSource() throws {
        openPage("hlsjs")
        XCTAssertTrue(eventually(40) { !self.nativeRequests("/hls/master.m3u8").isEmpty })
    }

    @MainActor func testStreamFoundThroughSrcProperty() throws {
        openPage("src")
        XCTAssertTrue(eventually(40) { !self.nativeRequests("/media/clip.mp4").isEmpty })
    }

    /// A tiny MP4 (the first piece of a stream the page assembles itself) is not a video: the app does not hand it to the iPhone's player.
    @MainActor func testTinyInitFileIsNotPlayedNatively() throws {
        openPage("initseg")
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 25), "the page is shown after a few seconds")
        sleep(5)
        let played = nativeRequests("/media/init.mp4").filter { ($0["range"] as? String ?? "") != "bytes=0-0" }
        XCTAssertTrue(played.isEmpty, "the app's player never played the tiny file (only its one-byte size check): \(played)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Played in the page player'")).firstMatch.exists == false, "no failure happened: it was never tried")
        assertNoExtraButtons()
    }

    /// A player that only loads its video once its play button is pressed: the app presses it (muted, out of sight).
    @MainActor func testPageThatWaitsForPlayIsStartedByTheApp() throws {
        openPage("lazy")
        XCTAssertTrue(eventually(40) { !self.nativeRequests("/media/clip.mp4").filter { ($0["range"] as? String ?? "") != "bytes=0-0" }.isEmpty }, "the app pressed play and then played the real stream")
    }

    /// A playlist served under a name and type that say nothing about it is recognised by its first line.
    @MainActor func testPlaylistWithoutPlaylistNameIsFound() throws {
        openPage("hlstxt")
        XCTAssertTrue(eventually(40) { !self.nativeRequests("/hls/master.txt").isEmpty }, "the app's player asked for the disguised master playlist")
    }

    private func playedNatively(_ path: String) -> Bool {
        !nativeRequests(path).filter { !["bytes=0-0", "bytes=0-4095"].contains($0["range"] as? String ?? "") }.isEmpty
    }

    /// A video element given an address with no file name (a plain /video/123 style link) is still a video: the app reads its first bytes.
    @MainActor func testAddressWithoutFileNameIsRecognisedByItsContent() throws {
        openPage("noext")
        XCTAssertTrue(eventually(40) { self.playedNatively("/media/clip") }, "the app's player played the address that has no file name")
    }

    /// The stream address only appears inside the page's own JSON answer.
    @MainActor func testStreamAddressInsideJsonIsFound() throws {
        openPage("api")
        XCTAssertTrue(eventually(40) { self.playedNatively("/media/clip.mp4") }, "the app's player played the address named in the JSON")
    }

    /// A page that keeps working for a while is not shown early: the stream turns up after about nine seconds.
    @MainActor func testBusyPageIsWaitedFor() throws {
        openPage("busy")
        XCTAssertTrue(eventually(60) { self.playedNatively("/media/clip.mp4") }, "the app's player played the stream that appeared late")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'no stream found'")).firstMatch.exists, "the page was not shown while it was still busy")
    }

    /// A page that never loads a stream (for example one waiting for a tap on its own play button) is shown after a few seconds.
    @MainActor func testPageWithoutAStreamIsShownAfterAWhile() throws {
        openPage("none")
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 20), "page shown with a close button")
        XCTAssertTrue(nativeRequests("/media/clip.mp4").isEmpty)
        assertNoExtraButtons()
    }
}

/// The player hides its buttons while a video plays, so tests touch the screen until the close button is there.
extension FeatureTestCase {
    func showControls() {
        let close = app.buttons["Close"]
        var tries = 0
        while !close.isHittable && tries < 8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            Thread.sleep(forTimeInterval: 0.6)
            tries += 1
        }
    }

    func playerOpened() -> Bool {
        let end = Date().addingTimeInterval(25)
        while Date() < end {
            if app.buttons["Close"].exists { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            Thread.sleep(forTimeInterval: 1)
        }
        return app.buttons["Close"].exists
    }
}

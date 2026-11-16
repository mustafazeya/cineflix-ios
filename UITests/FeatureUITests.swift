import XCTest

/// Talks to the two stand-in servers the feature tests need. Start them first:
///   node scripts/ui-test-servers/mock-sync.js   (port 8150)
///   node scripts/ui-test-servers/mock-tmdb.js   (port 8151)
enum Mock {
    static let sync = "http://127.0.0.1:8150"
    static let tmdb = "http://127.0.0.1:8151"

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

    override func setUp() {
        continueAfterFailure = false
        Mock.reset()
        app = XCUIApplication()
        app.launchArguments += ["-cf.noCast", "YES", "-cf.resetLibrary", "YES", "-cf.syncServer", Mock.sync]
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
        let p = Mock.item(email, defaultProfileName, "progress", "tv:8001")?["value"] as? [String: Any]
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

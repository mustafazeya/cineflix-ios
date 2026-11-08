import XCTest

/// End-to-end walk through the app. Needs the reference media server on localhost:8090 (tools/media-server.js).
final class CineFlixUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-cf.streamBase", "http://localhost:8090", "-cf.streamType", "auto", "-cf.hideWatched", "YES", "-cf.resetLibrary", "YES"]
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testEndToEnd() throws {
        XCTAssertTrue(app.staticTexts["Top 10 Today"].waitForExistence(timeout: 20), "home rows load")
        sleep(2)
        shot("01-home")

        // Search -> Big Buck Bunny (served by the local media server)
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Big Buck Bunny")
        let result = app.buttons["Big Buck Bunny"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "search finds the title")
        sleep(1)
        shot("02-search")
        result.tap()

        // Details
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "details show Play")
        sleep(2)
        shot("03-details")

        // Playback through the media server
        play.tap()
        sleep(9)
        shot("04-player")
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "player is showing")
        close.tap()

        // Continue Watching + Mark watched
        let markWatched = app.buttons["Mark watched"].firstMatch
        XCTAssertTrue(markWatched.waitForExistence(timeout: 10))
        markWatched.tap()
        XCTAssertTrue(app.buttons["Watched"].firstMatch.waitForExistence(timeout: 5), "button toggles to Watched")

        // My Stuff -> Watched
        app.tabBars.buttons["My Stuff"].tap()
        app.buttons["Watched"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Big Buck Bunny"].firstMatch.waitForExistence(timeout: 5), "title listed under Watched")
        shot("05-mystuff")

        // Browse
        app.tabBars.buttons["Browse"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'watched hidden'")).firstMatch.waitForExistence(timeout: 10))
        sleep(3)
        shot("06-browse")
    }
}

/// Subtitle search, run against the real SubDL service (key bundled via Secrets.xcconfig).
/// Needs: tools/media-server.js on :8090 (native HLS) and a plain player page without the bridge on :8112.
final class SubtitleUITests: XCTestCase {
    private func run(streamBase: String, type: String, _ name: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cf.streamBase", streamBase, "-cf.streamType", type, "-cf.resetLibrary", "YES"]
        app.launch()

        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Tears of Steel")
        let result = app.buttons["Tears of Steel"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15)); result.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15)); play.tap()

        let subs = app.buttons["Subtitles"].firstMatch
        XCTAssertTrue(subs.waitForExistence(timeout: 15), "subtitle button in player")
        sleep(6)
        subs.tap()

        XCTAssertTrue(app.staticTexts["Synced with the video"].waitForExistence(timeout: 15), "\(name): video clock reaches the app")
        let row = app.buttons.matching(identifier: "subtitle-result").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(name): subtitle results listed")
        let s1 = XCTAttachment(screenshot: app.screenshot()); s1.name = "\(name)-results"; s1.lifetime = .keepAlways; add(s1)
        row.tap()

        // The sheet closes after the download; the subtitle text then shows over the video.
        XCTAssertTrue(subs.waitForExistence(timeout: 25), "\(name): sheet closed after download")
        sleep(1)
        let s2 = XCTAttachment(screenshot: app.screenshot()); s2.name = "\(name)-on"; s2.lifetime = .keepAlways; add(s2)
        subs.tap()
        let off = app.buttons["Turn off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 10), "\(name): subtitle is on")
        let s3 = XCTAttachment(screenshot: app.screenshot()); s3.name = "\(name)-panel"; s3.lifetime = .keepAlways; add(s3)
        off.tap()
    }

    @MainActor func testPageWithoutBridge() throws { try run(streamBase: "http://localhost:8112", type: "page", "page") }
    @MainActor func testNativeVideo() throws { try run(streamBase: "http://localhost:8090", type: "auto", "native") }
}

/// The iPhone's own full screen video player must keep showing subtitles. Needs a player page with a "Maximise" button
/// on :8112 and a saved subtitle for Tears of Steel (see the seeding step in the test notes).
final class SubtitleFullscreenUITests: XCTestCase {
    @MainActor func testSubtitlesSurviveMaximise() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cf.streamBase", "http://localhost:8112", "-cf.streamType", "page", "-cf.resetLibrary", "YES"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Tears of Steel")
        let result = app.buttons["Tears of Steel"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15)); result.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15)); play.tap()

        let max = app.webViews.buttons["Maximise"].firstMatch
        XCTAssertTrue(max.waitForExistence(timeout: 20), "page shown")
        sleep(4)
        let inline = XCTAttachment(screenshot: app.screenshot()); inline.name = "fs-inline"; inline.lifetime = .keepAlways; add(inline)
        max.tap()
        sleep(5)
        let full = XCTAttachment(screenshot: app.screenshot()); full.name = "fs-full"; full.lifetime = .keepAlways; add(full)
    }
}

/// The Home hero has Play, My List and a Details button that opens the title's page.
final class HeroUITests: XCTestCase {
    @MainActor func testHeroDetailsButton() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cf.resetLibrary", "YES"]
        app.launch()
        let details = app.buttons["hero-details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 25), "hero shows a Details button")
        sleep(2)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "hero"; a.lifetime = .keepAlways; add(a)
        details.tap()
        let onPage = NSPredicate(format: "isHittable == false")
        expectation(for: onPage, evaluatedWith: details)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 15), "Details opens the title page (back button shown)")
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "details"; b.lifetime = .keepAlways; add(b)
    }
}

import XCTest

/// Accounts, profiles and sign-in against the live sync service. Uses an @example.com address that is deleted afterwards.
final class SyncUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-cf.resetLibrary", "YES"]
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testAccountAndProfiles() throws {
        app.tabBars.buttons["My Stuff"].tap()
        let guest = app.buttons["guest-card"]
        XCTAssertTrue(guest.waitForExistence(timeout: 20), "guest card visible")
        shot("s01-guest")
        guest.tap()

        let email = app.textFields["signin-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        shot("s02-signin")
        app.buttons["New here? Create an account"].tap()
        email.tap()
        email.typeText("ios-ui-\(Int(Date().timeIntervalSince1970))@example.com")
        let pw = app.secureTextFields["signin-password"]
        pw.tap()
        pw.typeText("correct horse battery")
        shot("s03-create")
        app.buttons["signin-submit"].tap()

        // The server gives a new account one profile; the picker follows sign-in.
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 30), "picker after sign-in")
        sleep(2)
        shot("s04-picker")

        // Add a second profile with a chosen avatar.
        app.buttons["profile-add"].tap()
        let name = app.textFields["profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Sadiqa")
        app.buttons["change-avatar"].tap()
        XCTAssertTrue(app.staticTexts["ANIMALS"].waitForExistence(timeout: 5))
        sleep(1)
        shot("s05-avatars")
        app.buttons["avatar-panda"].tap()
        shot("s06-editor")
        app.buttons["profile-save"].tap()
        XCTAssertTrue(app.buttons["profile-Sadiqa"].waitForExistence(timeout: 10), "new profile listed")
        shot("s07-two-profiles")

        // Choose it.
        app.buttons["profile-Sadiqa"].tap()
        let menu = app.buttons["account-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "account card after choosing")
        sleep(2)
        shot("s08-mystuff")

        // Sign out returns to guest.
        menu.tap()
        app.buttons["Sign out"].tap()
        app.buttons["Sign out"].tap()
        XCTAssertTrue(app.buttons["guest-card"].waitForExistence(timeout: 10), "back to guest")
    }
}

/// My Videos: add a link by name, see it listed, play it.
final class MyVideosUITests: XCTestCase {
    @MainActor func testAddAndPlayVideo() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cf.resetLibrary", "YES"]
        app.launch()
        app.tabBars.buttons["My Stuff"].tap()
        app.buttons["Videos"].firstMatch.tap()
        let addBtn = app.buttons["video-add"]
        XCTAssertTrue(addBtn.waitForExistence(timeout: 20))
        addBtn.tap()
        let name = app.textFields["video-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Holiday clip")
        let link = app.textFields["video-link"]
        link.tap()
        link.typeText("http://localhost:8120/clip.mp4")
        let shot1 = XCTAttachment(screenshot: app.screenshot()); shot1.name = "v-editor"; shot1.lifetime = .keepAlways; add(shot1)
        app.buttons["video-save"].tap()
        let row = app.buttons["video-Holiday clip"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "saved video is listed")
        let shot2 = XCTAttachment(screenshot: app.screenshot()); shot2.name = "v-list"; shot2.lifetime = .keepAlways; add(shot2)
        row.tap()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 15), "player opens")
        sleep(5)
        let shot3 = XCTAttachment(screenshot: app.screenshot()); shot3.name = "v-play"; shot3.lifetime = .keepAlways; add(shot3)
        XCTAssertFalse(app.buttons["Subtitles"].exists, "no subtitle search for saved links")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "back on the list")
        // Survives a relaunch (stored on the phone)
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["My Stuff"].tap()
        app.buttons["Videos"].firstMatch.tap()
        XCTAssertTrue(app.buttons["video-Holiday clip"].waitForExistence(timeout: 20), "still there after relaunch")
    }
}

/// MEGA folders: add a link, browse the folder, play an MP4 from it. Needs the stand-in MEGA server on :8130.
final class MegaUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func testBrowseAndPlayMegaFolder() throws {
        let truth = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(string: "http://127.0.0.1:8130/truth.json")!)) as! [String: Any]
        let link = "https://mega.nz/folder/ROOT0001#" + (truth["folderKey"] as! String)
        let app = XCUIApplication()
        app.launchArguments += ["-cf.resetLibrary", "YES", "-cf.megaApi", "http://127.0.0.1:8130/cs"]
        app.launch()
        app.tabBars.buttons["My Stuff"].tap()
        app.buttons["Videos"].firstMatch.tap()
        app.buttons["video-add"].tap()
        let field = app.textFields["video-link"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        UIPasteboard.general.string = link
        field.press(forDuration: 1.0)
        if app.menuItems["Paste"].waitForExistence(timeout: 3) { app.menuItems["Paste"].tap() } else { field.typeText(link) }
        XCTAssertTrue(app.staticTexts["MEGA folder found. You pick what to watch from its list."].waitForExistence(timeout: 5), "link recognised")
        shot(app, "m-editor")
        app.buttons["video-save"].tap()
        let row = app.buttons["video-Family Videos"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "saved with the folder's name")
        shot(app, "m-list")
        row.tap()
        XCTAssertTrue(app.buttons["mega-Real clip.mp4"].waitForExistence(timeout: 15), "folder lists its video")
        XCTAssertFalse(app.buttons["mega-notes.txt"].exists, "non-video files are hidden")
        sleep(1)
        shot(app, "m-browse")
        app.buttons["mega-folder-Season 1"].firstMatch.tap()
        XCTAssertTrue(app.buttons["mega-Episode 2.mkv"].waitForExistence(timeout: 10), "subfolder opens")
        shot(app, "m-sub")
        app.buttons["mega-Episode 2.mkv"].tap()
        XCTAssertTrue(app.alerts["Can't play this here"].waitForExistence(timeout: 5), "mkv explains itself")
        app.alerts.buttons["OK"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["mega-Real clip.mp4"].tap()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 15), "player opens")
        sleep(6)
        shot(app, "m-play")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'iPhone can'")).firstMatch.exists, "no error shown while playing")
    }
}

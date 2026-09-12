import XCTest

final class SupportLinksUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testBothLinksUsePublicDestinationsWithoutApplyingDraftOrRequestingPermission() throws {
        launch()
        try verifyDocument(identifier: "privacy-policy-link", file: "PRIVACY")
        try verifyDocument(identifier: "support-link", file: "SUPPORT", editDraft: true)
    }

    func testDiscardedURLOpenPreservesDraftAndRunningApp() throws {
        launch(discardURLs: true)
        try verifyDocument(identifier: "privacy-policy-link", file: "PRIVACY", editDraft: true)
    }

    func testBothLinksRemainReachableAtLargestTextInPublicRelease() throws {
        launch(largestText: true)
        try verifyDocument(identifier: "privacy-policy-link", file: "PRIVACY", editDraft: true, largestText: true)
        // Keep the two largest-text navigation cases independent.
        app.terminate()
        launch(largestText: true)
        try verifyDocument(identifier: "support-link", file: "SUPPORT", editDraft: true, largestText: true)
    }

    private func launch(largestText: Bool = false, discardURLs: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment["SONYGEOTAG_UI_SCENARIO"] = largestText ? "public-release-settings" : "first-run"
        if discardURLs {
            app.launchEnvironment["SONYGEOTAG_UI_DISCARD_URLS"] = "1"
        }
        if largestText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
                "-AppleInterfaceStyle", "Dark",
            ]
        }
        app.launch()
    }

    private func verifyDocument(
        identifier: String, file: String, editDraft: Bool = false, largestText: Bool = false
    ) throws {
        let settings = app.buttons["link-settings"]
        scrollUntilVisible(settings)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Link Settings"].waitForExistence(timeout: 5))
        if editDraft {
            let accuracy = app.buttons["Best Accuracy"]
            scrollUntilVisible(accuracy)
            accuracy.tap()
            XCTAssertTrue(app.buttons["settings-apply"].isEnabled)
        }
        let link = app.buttons[identifier]
        scrollUntilVisible(link)
        XCTAssertTrue(link.isHittable)
        XCTAssertGreaterThanOrEqual(link.frame.minY, app.navigationBars["Link Settings"].frame.maxY)
        XCTAssertLessThanOrEqual(link.frame.maxY, app.frame.maxY - 40)
        XCTAssertEqual(link.label, file == "PRIVACY" ? "Privacy Policy" : "Support")
        link.tap()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.navigationBars["Link Settings"].exists)
        XCTAssertEqual(app.buttons["settings-apply"].isEnabled, editDraft)
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["settings-cancel"].tap()

        let destination = app.staticTexts["ui-test-opened-url"]
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        XCTAssertEqual(destination.label, "https://github.com/narumiruna/camera-gps-link/blob/main/docs/\(file).md")
        XCTAssertTrue(app.staticTexts["While Open · Battery Saver"].exists)
        XCTAssertTrue(app.staticTexts["Not Connected"].exists)
        if !largestText {
            XCTAssertTrue(app.staticTexts["Not requested"].exists)
        }
    }

    private func scrollUntilVisible(_ element: XCUIElement) {
        for _ in 0..<20 {
            let settingsBar = app.navigationBars["Link Settings"]
            let navigationBar = settingsBar.exists ? settingsBar : app.navigationBars.firstMatch
            let top = navigationBar.frame.maxY + 8
            let bottom = app.frame.maxY - 40
            let frame = element.exists ? element.frame : .zero
            // Off-screen SwiftUI nodes can report an invalid activation point during a scroll.
            // Poll geometry only; verify the actual button's hittability after it is fully visible.
            if !frame.isEmpty, frame.minX >= app.frame.minX, frame.maxX <= app.frame.maxX,
                frame.minY >= top, frame.maxY <= bottom
            {
                return
            }
            let scrollDown = !frame.isEmpty && frame.minY < top
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.78 : 0.32))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
}

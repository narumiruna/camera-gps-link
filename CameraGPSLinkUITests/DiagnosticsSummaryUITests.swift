import XCTest

final class DiagnosticsSummaryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testEmptyLogStillOffersUsefulSummaryAndCopyFeedback() {
        launch("empty-diagnostics")
        openDiagnostics()
        let copy = app.buttons["copy-diagnostic-summary"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.isEnabled)
        copy.tap()
        XCTAssertTrue(app.buttons["Copied Diagnostic Summary"].exists)
        app.buttons["Summary Preview"].tap()
        let preview = app.staticTexts["diagnostic-summary-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(preview.label.contains("Camera model: ILCE-7CM2"))
        XCTAssertTrue(preview.label.contains("Last camera update: Not sent yet"))
        XCTAssertFalse(preview.label.contains("35.681236"))
        scrollUntilVisible(app.buttons["copy-diagnostics"])
        XCTAssertFalse(app.buttons["copy-diagnostics"].isEnabled)
    }

    func testSummaryCopyDoesNotStartGeotaggingOrRequestLocation() {
        launch("first-run")
        openDiagnostics()
        app.buttons["copy-diagnostic-summary"].tap()
        XCTAssertTrue(app.buttons["Copied Diagnostic Summary"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Not Connected"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Start Geotagging"].exists)
        XCTAssertTrue(app.staticTexts["Not requested"].exists)
    }

    func testSummaryCopyAndPreviewRemainReachableWithLargestText() throws {
        launch("empty-diagnostics", largestText: true)
        openDiagnostics()
        let copy = app.buttons["copy-diagnostic-summary"]
        scrollUntilVisible(copy)
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["Copied Diagnostic Summary"].exists)
        let preview = app.buttons["Summary Preview"]
        scrollUntilVisible(preview)
        XCTAssertTrue(preview.isHittable)
        try app.performAccessibilityAudit(
            for: [.contrast, .hitRegion, .sufficientElementDescription, .textClipped, .trait]
        )
        preview.tap()
        XCTAssertTrue(app.staticTexts["diagnostic-summary-preview"].exists)
    }

    private func launch(_ scenario: String, largestText: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment["SONYGEOTAG_UI_SCENARIO"] = scenario
        if largestText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
                "-AppleInterfaceStyle", "Dark",
            ]
        }
        app.launch()
    }

    private func openDiagnostics() {
        let link = app.buttons["diagnostics-link"]
        scrollUntilVisible(link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
    }

    private func scrollUntilVisible(_ element: XCUIElement) {
        for _ in 0..<16 {
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = app.frame.maxY - 40
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty, frame.minY >= top, frame.maxY <= bottom, element.isHittable {
                return
            }
            // Short, reversible drags avoid flinging a large-text row past the navigation bar.
            let scrollDown = !frame.isEmpty && frame.minY < top
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.78 : 0.32))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
}

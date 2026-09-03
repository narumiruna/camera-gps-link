import XCTest

final class ConnectionHealthUITests: XCTestCase {
    private struct HealthScenario {
        let name: String
        let detail: String
        let notice: String
    }

    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        app = nil
        super.tearDown()
    }

    func testHealthAlertSettingPreservesCancelAndAppliesWithoutSystemPrompt() {
        launch("not-connected")
        openLinkSettings()
        let toggle = app.switches["health-alerts-toggle"]
        scrollUntilVisible(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(permissionStatus("Allowed").exists)
        app.buttons["settings-cancel"].tap()

        openLinkSettings()
        let reopenedToggle = app.switches["health-alerts-toggle"]
        scrollUntilVisible(reopenedToggle)
        XCTAssertEqual(reopenedToggle.value as? String, "0")
        reopenedToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["health-alerts-toggle"].value as? String, "1")
        XCTAssertTrue(app.buttons["settings-apply"].isEnabled)
        app.buttons["settings-apply"].tap()
        waitForDisappearance(app.navigationBars["Link Settings"])
        openLinkSettings()
        XCTAssertEqual(app.switches["health-alerts-toggle"].value as? String, "1")
        XCTAssertTrue(permissionStatus("Allowed").exists)
    }

    func testBlockedHealthAlertPermissionOffersSettingsRecovery() {
        launch("health-alerts-blocked")
        openLinkSettings()

        XCTAssertTrue(permissionStatus("Blocked in iOS Settings").exists)
        XCTAssertTrue(app.buttons["health-alerts-open-settings"].exists)
    }

    func testLocationHealthFixturesUseDistinctActionableCopy() {
        let scenarios = [
            HealthScenario(name: "stale-location", detail: "Stale · 2 minutes ago", notice: "iPhone Location Is Stale"),
            HealthScenario(name: "low-accuracy", detail: "Low accuracy · ±101 m", notice: "Low Location Accuracy"),
            HealthScenario(
                name: "future-location", detail: "Fix time invalid", notice: "iPhone Location Needs Attention"),
            HealthScenario(name: "invalid-location", detail: "Invalid fix", notice: "iPhone Location Needs Attention"),
        ]

        for scenario in scenarios {
            launch(scenario.name)
            XCTAssertTrue(app.staticTexts["Ready to Geotag"].waitForExistence(timeout: 5), scenario.name)
            XCTAssertTrue(app.staticTexts[scenario.detail].exists, scenario.name)
            XCTAssertTrue(app.staticTexts[scenario.notice].exists, scenario.name)
            if scenario.name == "low-accuracy" {
                XCTAssertTrue(app.buttons["Send Current Location"].exists)
            } else {
                XCTAssertFalse(app.buttons["Send Current Location"].exists)
            }
            app.terminate()
        }
    }

    func testStaleCameraUpdateAndCoexistingNoticesDoNotClaimFullReadiness() {
        launch("stale-camera-update")
        XCTAssertTrue(app.staticTexts["Location Update Delayed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Ready to Geotag"].exists)

        app.terminate()
        launch("coexisting-notices")
        let locationNotice = app.staticTexts["iPhone Location Is Stale"]
        let permissionNotice = app.staticTexts["Background Permission Needed"]
        XCTAssertTrue(locationNotice.waitForExistence(timeout: 5))
        XCTAssertTrue(permissionNotice.exists)
        XCTAssertLessThan(locationNotice.frame.minY, permissionNotice.frame.minY)
    }

    func testHealthNoticesPassAccessibilityAuditAndRemainReachableInLandscape() throws {
        launch(
            "coexisting-notices",
            arguments: [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
                "-AppleInterfaceStyle", "Dark",
                "-UIAccessibilityDarkerSystemColorsEnabled", "YES",
                "-UIAccessibilityReduceMotionEnabled", "YES",
            ]
        )
        XCTAssertTrue(app.staticTexts["iPhone Location Is Stale"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(
            for: [.contrast, .hitRegion, .sufficientElementDescription, .textClipped, .trait]
        )

        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        launch("low-accuracy")
        scrollUntilVisible(app.buttons["Send Current Location"])
        XCTAssertTrue(app.buttons["Send Current Location"].isHittable)
    }

    func testForegroundSuspensionFixtureRecordsSanitizedAlertEvent() {
        launch("health-alerts-foreground-suspension")
        app.buttons["diagnostics-link"].tap()
        let event = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Health alert scheduled: foreground suspension'")
        ).firstMatch
        scrollUntilVisible(event)
        XCTAssertTrue(event.exists)
    }

    private func permissionStatus(_ status: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", status)
        ).firstMatch
    }

    private func launch(_ scenario: String, arguments: [String] = []) {
        app = XCUIApplication()
        app.launchEnvironment["SONYGEOTAG_UI_SCENARIO"] = scenario
        app.launchArguments += arguments
        app.launch()
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func openLinkSettings() {
        let navigationBar = app.navigationBars["Link Settings"]
        for _ in 0..<3 {
            let button = app.buttons["link-settings"]
            scrollUntilVisible(button)
            if button.isHittable {
                button.tap()
            }
            if navigationBar.waitForExistence(timeout: 3) {
                return
            }
        }
        XCTFail("Link Settings did not open")
    }

    private func scrollUntilVisible(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
}

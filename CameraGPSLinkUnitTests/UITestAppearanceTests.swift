#if DEBUG
    import SwiftUI
    import XCTest

    @testable import CameraGPSLink

    final class UITestAppearanceTests: XCTestCase {
        func testExplicitLightDoesNotInheritSystemAppearance() {
            XCTAssertEqual(UITestAppearance.colorScheme(for: "Light"), .light)
        }

        func testExplicitDarkDoesNotInheritSystemAppearance() {
            XCTAssertEqual(UITestAppearance.colorScheme(for: "Dark"), .dark)
        }

        func testMissingOrUnsupportedAppearanceInheritsSystemAppearance() {
            for value: String? in [nil, "", "Automatic", "light"] {
                XCTAssertNil(UITestAppearance.colorScheme(for: value))
            }
        }
    }
#endif

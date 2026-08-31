import SwiftUI
import UIKit
import XCTest
@testable import Litter

final class LitterAppearanceModeTests: XCTestCase {
    func testPreferredColorSchemeMapping() {
        XCTAssertNil(LitterAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(LitterAppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(LitterAppearanceMode.dark.preferredColorScheme, .dark)
    }

    func testResolvedColorSchemeUsesSystemOnlyForSystemMode() {
        XCTAssertEqual(LitterAppearanceMode.system.resolvedColorScheme(systemColorScheme: .light), .light)
        XCTAssertEqual(LitterAppearanceMode.system.resolvedColorScheme(systemColorScheme: .dark), .dark)
        XCTAssertEqual(LitterAppearanceMode.light.resolvedColorScheme(systemColorScheme: .dark), .light)
        XCTAssertEqual(LitterAppearanceMode.dark.resolvedColorScheme(systemColorScheme: .light), .dark)
    }

    func testUserInterfaceStyleMapping() {
        XCTAssertEqual(LitterAppearanceMode.system.userInterfaceStyle, .unspecified)
        XCTAssertEqual(LitterAppearanceMode.light.userInterfaceStyle, .light)
        XCTAssertEqual(LitterAppearanceMode.dark.userInterfaceStyle, .dark)
    }
}

final class WallpaperConfigOptionalStateTests: XCTestCase {
    func testMissingConfigIsNeitherActiveNorAnExplicitNoneSelection() {
        let config: WallpaperConfig? = nil

        XCTAssertFalse(config.containsActiveWallpaper)
        XCTAssertFalse(config.explicitlySelectsNoWallpaper)
    }

    func testExplicitNoneConfigIsSelectedButNotActive() {
        let config: WallpaperConfig? = WallpaperConfig(type: WallpaperType.none)

        XCTAssertFalse(config.containsActiveWallpaper)
        XCTAssertTrue(config.explicitlySelectsNoWallpaper)
    }

    func testNonNoneConfigIsActiveAndNotAnExplicitNoneSelection() {
        let config: WallpaperConfig? = WallpaperConfig(
            type: WallpaperType.theme,
            themeSlug: "midnight"
        )

        XCTAssertTrue(config.containsActiveWallpaper)
        XCTAssertFalse(config.explicitlySelectsNoWallpaper)
    }
}

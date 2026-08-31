import XCTest
@testable import boringNotch

final class NotchContentPreferencesTests: XCTestCase {
    func testCodexDisplayModeMigratesLegacyActivityChoice() {
        XCTAssertEqual(
            CodexDisplayMode.resolved(storedValue: nil, legacyActivityEnabled: true),
            .fullActivity
        )
        XCTAssertEqual(
            CodexDisplayMode.resolved(storedValue: nil, legacyActivityEnabled: false),
            .off
        )
        XCTAssertEqual(
            CodexDisplayMode.resolved(
                storedValue: CodexDisplayMode.usageOnly.rawValue,
                legacyActivityEnabled: true
            ),
            .usageOnly
        )
    }

    func testCodexDisplayModesExposeOnlyRequestedContent() {
        XCTAssertFalse(CodexDisplayMode.off.showsCodex)
        XCTAssertFalse(CodexDisplayMode.off.monitorsActivity)
        XCTAssertTrue(CodexDisplayMode.usageOnly.showsCodex)
        XCTAssertFalse(CodexDisplayMode.usageOnly.monitorsActivity)
        XCTAssertTrue(CodexDisplayMode.fullActivity.showsCodex)
        XCTAssertTrue(CodexDisplayMode.fullActivity.monitorsActivity)
    }
}

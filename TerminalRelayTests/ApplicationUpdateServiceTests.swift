import XCTest
@testable import TerminalRelay

@MainActor
final class ApplicationUpdateServiceTests: XCTestCase {
    func testBundledUpdaterConfigurationIsSignedPrivateAndDaily() {
        XCTAssertTrue(
            ApplicationUpdateConfiguration.isValid(
                infoDictionary: Bundle.main.infoDictionary ?? [:]
            )
        )
    }

    func testUnitTestsDisableUpdaterNetworkActivity() {
        XCTAssertFalse(
            ApplicationUpdateConfiguration.shouldStartUpdater(
                environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]
            )
        )
        XCTAssertTrue(ApplicationUpdateConfiguration.shouldStartUpdater(environment: [:]))
        XCTAssertEqual(ApplicationUpdateConfiguration.commandTitle, "Check for Updates…")
    }
}

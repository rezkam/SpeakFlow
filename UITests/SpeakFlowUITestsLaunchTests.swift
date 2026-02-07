import XCTest

@MainActor
final class SpeakFlowUITestsLaunchTests: XCTestCase {
    func testLaunchHarnessWindow() {
        let app = XCUIApplication()
        app.launchEnvironment["SPEAKFLOW_UI_TEST_MODE"] = "1"
        app.launchEnvironment["SPEAKFLOW_UI_TEST_MOCK_RECORDING"] = "1"
        app.launchEnvironment["SPEAKFLOW_UI_TEST_RESET_STATE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows["ui_test.window"].waitForExistence(timeout: 8))
    }
}

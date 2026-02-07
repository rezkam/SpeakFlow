import XCTest

@MainActor
final class SpeakFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testClickStartStopFlow() throws {
        let app = launchHarness()
        let startButton = app.buttons["ui_test.start_button"]
        let stopButton = app.buttons["ui_test.stop_button"]
        let statusValue = app.staticTexts["ui_test.status_value"]

        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertTrue(stopButton.exists)
        XCTAssertTrue(statusValue.exists)

        startButton.tap()
        waitForLabel(statusValue, toEqual: "recording")

        stopButton.tap()
        waitForLabel(statusValue, toEqual: "idle")
    }

    func testHotkeyFlow() throws {
        let app = launchHarness()
        let window = app.windows["ui_test.window"]
        let statusValue = app.staticTexts["ui_test.status_value"]
        let toggleCountValue = app.staticTexts["ui_test.toggle_count_value"]

        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(statusValue.exists)
        XCTAssertTrue(toggleCountValue.exists)

        waitForLabel(toggleCountValue, toEqual: "0")

        window.tap()
        window.typeKey("d", modifierFlags: [.control, .option])
        waitForLabel(statusValue, toEqual: "recording")
        waitForLabel(toggleCountValue, toEqual: "1")

        window.typeKey("d", modifierFlags: [.control, .option])
        waitForLabel(statusValue, toEqual: "idle")
        waitForLabel(toggleCountValue, toEqual: "2")
    }

    func testChangingHotkeyUpdatesActiveTrigger() throws {
        let app = launchHarness()
        let window = app.windows["ui_test.window"]
        let nextHotkeyButton = app.buttons["ui_test.next_hotkey_button"]
        let hotkeyValue = app.staticTexts["ui_test.hotkey_value"]
        let statusValue = app.staticTexts["ui_test.status_value"]
        let toggleCountValue = app.staticTexts["ui_test.toggle_count_value"]

        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(nextHotkeyButton.exists)
        XCTAssertTrue(hotkeyValue.exists)
        XCTAssertTrue(toggleCountValue.exists)

        waitForLabel(hotkeyValue, toEqual: "⌃⌥D")
        waitForLabel(toggleCountValue, toEqual: "0")

        // Wrong key for current hotkey (⌃⌥D): should not toggle.
        window.tap()
        window.typeKey("d", modifierFlags: [.command, .shift])
        assertLabel(toggleCountValue, equals: "0")

        // Switch to ⌃⌥Space and verify only that key toggles.
        nextHotkeyButton.tap()
        waitForLabel(hotkeyValue, toEqual: "⌃⌥Space")
        window.typeKey("d", modifierFlags: [.control, .option])
        assertLabel(toggleCountValue, equals: "0")

        window.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [.control, .option])
        waitForLabel(statusValue, toEqual: "recording")
        waitForLabel(toggleCountValue, toEqual: "1")

        window.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [.control, .option])
        waitForLabel(statusValue, toEqual: "idle")
        waitForLabel(toggleCountValue, toEqual: "2")
    }

    func testStatisticsSeedAndResetFlow() throws {
        let app = launchHarness()
        let seedButton = app.buttons["ui_test.seed_stats_button"]
        let resetButton = app.buttons["ui_test.reset_stats_button"]
        let apiCallsValue = app.staticTexts["ui_test.stats_api_calls_value"]
        let wordsValue = app.staticTexts["ui_test.stats_words_value"]

        XCTAssertTrue(seedButton.waitForExistence(timeout: 5))
        XCTAssertTrue(resetButton.exists)
        XCTAssertTrue(apiCallsValue.exists)
        XCTAssertTrue(wordsValue.exists)

        waitForLabel(apiCallsValue, toEqual: "0")
        waitForLabel(wordsValue, toEqual: "0")

        seedButton.tap()
        waitForLabel(apiCallsValue, toEqual: "1")
        waitForLabel(wordsValue, toEqual: "4")

        resetButton.tap()
        waitForLabel(apiCallsValue, toEqual: "0")
        waitForLabel(wordsValue, toEqual: "0")
    }

    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SPEAKFLOW_UI_TEST_MODE"] = "1"
        app.launchEnvironment["SPEAKFLOW_UI_TEST_MOCK_RECORDING"] = "1"
        app.launchEnvironment["SPEAKFLOW_UI_TEST_RESET_STATE"] = "1"
        app.launch()
        XCTAssertTrue(app.windows["ui_test.window"].waitForExistence(timeout: 8))
        return app
    }

    private func waitForLabel(_ element: XCUIElement, toEqual expected: String, timeout: TimeInterval = 2.0) {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed)
    }

    private func assertLabel(_ element: XCUIElement, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(element.label, expected, file: file, line: line)
    }
}

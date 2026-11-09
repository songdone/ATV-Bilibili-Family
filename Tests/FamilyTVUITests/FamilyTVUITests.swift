import XCTest

final class FamilyTVUITests: XCTestCase {
    /// tvOS has no direct hardware-keyboard path in XCUITest: select the focused
    /// alert field to summon the system keyboard, type through it, then commit
    /// with a return keystroke (menu would revert the edit).
    private func typeIntoAlertField(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(text)
        field.typeText("\n")
        expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: app.keyboards)
        waitForExpectations(timeout: 5)
    }
    private func setupParent(_ app: XCUIApplication) {
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        let entry = app.cells["家长验证"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: entry)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创建六位家长 PIN"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: app.cells["family-pin-1"])
        waitForExpectations(timeout: 5)
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.staticTexts["请再次输入相同 PIN。"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
    }

    private func selectRow(_ app: XCUIApplication, _ title: String, maxSteps: Int = 24) {
        let row = app.cells[title]
        for _ in 0..<maxSteps {
            if row.exists && row.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(row.exists && row.hasFocus, title)
        XCUIRemote.shared.press(.select)
    }

    func testForcedQuizCannotBeSavedWithoutPlayableChildQuestions() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        setupParent(app)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["添加孩子"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        selectRow(app, "添加孩子")
        XCTAssertTrue(app.cells["孩子昵称"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.cells["孩子昵称"].hasFocus)
        XCUIRemote.shared.press(.select)
        typeIntoAlertField(app, "题库检查")
        XCTAssertTrue(app.cells["孩子昵称"].value as? String == "题库检查")
        selectRow(app, "完成")
        XCTAssertTrue(app.cells["题库检查 · 1"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.left)
        for _ in 0..<5 {
            if app.cells["family-nav-学习奖励"].hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(app.cells["开启答题奖励"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        selectRow(app, "开启答题奖励")
        XCTAssertTrue(app.cells["每天第一次看之前先答题"].waitForExistence(timeout: 5))
        if app.cells["每天第一次看之前先答题"].value as? String != "开" {
            selectRow(app, "每天第一次看之前先答题")
        }
        // The rejection is shown at the top of the page; focus is still on the
        // switch, so walk back up before reading it.
        for _ in 0..<24 { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(app.cells["没有生效"].waitForExistence(timeout: 10), "rejected gate must explain why")
        XCTAssertTrue(app.cells["没有生效"].hasFocus)
        // The reason and the fix must be readable on the row without opening
        // anything or leaving the page.
        let reason = app.cells["没有生效"].value as? String ?? ""
        XCTAssertTrue(reason.contains("答题科目"), "row must state the fix, got: \(reason)")
        // The reward switch itself is allowed; only the unusable watch gate is
        // rejected. Relaunch to prove which half persisted.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.cells["家长验证"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["家长验证"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
        for _ in 0..<3 { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(app.cells["开启答题奖励"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["开启答题奖励"].value as? String, "开")
        XCTAssertTrue(app.cells["每天第一次看之前先答题"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["每天第一次看之前先答题"].value as? String, "关")
    }

    func testReportRemainsAvailableWithinParentSessionAfterFetchTokenExpires() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        setupParent(app)
        for _ in 0..<4 { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(app.cells["验证并读取报告"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        selectRow(app, "验证并读取报告")
        XCTAssertTrue(app.cells["按日期查看"].waitForExistence(timeout: 10))
        sleep(65)
        XCTAssertTrue(app.cells["按日期查看"].exists, "report viewing must use the live 10 minute parent session")
        selectRow(app, "按日期查看")
        XCTAssertFalse(app.staticTexts["家长验证"].exists)
        XCUIRemote.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.cells["家长验证"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.cells["按日期查看"].exists)
    }

    func testAdultPlaybackPreservedAndModeSwitchRevokesOldPlayer() throws {
        guard FileManager.default.fileExists(atPath: "/tmp/ATVFamilyProbe.mp4") else { throw XCTSkip("Generate offline media first") }
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString,
                               "--family-probe-adult", "--family-probe-media", "/tmp/ATVFamilyProbe.mp4"]
        app.launch()
        let result = app.staticTexts["family-adult-probe-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertTrue(result.label.hasPrefix("ADULT VERIFIED"), result.label)
        let attachment = XCTAttachment(string: result.label)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testQuizGateOpensRealBankQuizAndShowsOutcome() throws {
        let source = ProcessInfo.processInfo.environment["FAMILY_SOURCE_ROOT"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let bankURL = URL(fileURLWithPath: source).appendingPathComponent("BilibiliLive/QuestionBank/grade4-general.json")
        let bank = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: bankURL)) as? [String: Any])
        let questions = try XCTUnwrap(bank["questions"] as? [[String: Any]])
        var answerIDs = [String: String]()
        for question in questions {
            let id = try XCTUnwrap(question["question_id"] as? String)
            answerIDs[id] = try XCTUnwrap(question["answer"] as? String)
        }
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString, "--family-probe-quiz"]
        app.launch()
        XCTAssertTrue(app.staticTexts["答题闯关"].waitForExistence(timeout: 35))
        for _ in 0..<5 {
            let prompt = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quiz-question-")).firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10))
            let identifier = prompt.identifier
            let id = String(identifier.dropFirst("quiz-question-".count))
            let answer = try XCTUnwrap(answerIDs[id], "Question must originate from the bundled bank")
            let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quiz-option-")).allElementsBoundByIndex
                .sorted { $0.frame.minY < $1.frame.minY }
            let first = try XCTUnwrap(options.first)
            expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: first)
            waitForExpectations(timeout: 5)
            let target = try XCTUnwrap(options.firstIndex { $0.identifier == "quiz-option-" + answer })
            for _ in 0..<target { XCUIRemote.shared.press(.down) }
            XCTAssertTrue(app.buttons["quiz-option-" + answer].hasFocus)
            XCUIRemote.shared.press(.select)
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts[identifier])
            waitForExpectations(timeout: 5)
        }
        let outcome = app.staticTexts["quiz-outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 10))
        XCTAssertEqual(outcome.label, "本轮通过")
        XCTAssertTrue(app.staticTexts["quiz-reward"].label.contains("10 分钟"))
        let finish = app.buttons["完成"]
        for _ in 0..<10 {
            if finish.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(finish.hasFocus)
        XCUIRemote.shared.press(.select)
        let evidence = app.staticTexts["family-playback-probe-result"]
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "QUIZ VERIFIED"), evaluatedWith: evidence)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(evidence.label.contains("reward=600000 playable=true"))
        let attachment = XCTAttachment(string: evidence.label)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRealQuizGateCompletionAutomaticallyResumesBilledVideo() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bank = try XCTUnwrap(try JSONSerialization.jsonObject(with:
            Data(contentsOf: source.appendingPathComponent("BilibiliLive/QuestionBank/grade4-general.json"))) as? [String: Any])
        let questions = try XCTUnwrap(bank["questions"] as? [[String: Any]])
        let answers = Dictionary(uniqueKeysWithValues: try questions.map {
            (try XCTUnwrap($0["question_id"] as? String), try XCTUnwrap($0["answer"] as? String))
        })
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString,
            "--family-probe-quiz-resume", "--family-probe-media", "/tmp/ATVFamilyProbe.mp4"]
        app.launch()
        let start = app.buttons["family-quiz-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: start)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["答题闯关"].waitForExistence(timeout: 10))
        // Cancel without answering, then re-enter the real gate before completing.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: start)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["答题闯关"].waitForExistence(timeout: 10))
        for _ in 0..<5 {
            let prompt = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quiz-question-")).firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            let id = String(prompt.identifier.dropFirst("quiz-question-".count))
            let answer = try XCTUnwrap(answers[id])
            let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quiz-option-")).allElementsBoundByIndex
                .sorted { $0.frame.minY < $1.frame.minY }
            let first = try XCTUnwrap(options.first)
            expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: first)
            waitForExpectations(timeout: 5)
            let target = try XCTUnwrap(options.firstIndex { $0.identifier == "quiz-option-" + answer })
            for _ in 0..<target { XCUIRemote.shared.press(.down) }
            XCUIRemote.shared.press(.select)
        }
        XCTAssertTrue(app.staticTexts["quiz-outcome"].waitForExistence(timeout: 10))
        let finish = app.buttons["quiz-complete"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: finish)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        let evidence = app.staticTexts["family-clock-recovery-played"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 20), "quiz completion must lead to a new actual player, not just a reservable ledger")
        XCTAssertTrue(evidence.label.hasPrefix("CLOCK RECOVERY PLAYED"), evidence.label)
        let record = XCTAttachment(string: evidence.label)
        record.name = "Production quiz gate to billed video"
        record.lifetime = .keepAlways
        add(record)
    }

    func testClockPlaybackSurvivesProcessRelaunchWithoutResettingHousehold() throws {
        let media = "/tmp/ATVFamilyProbe.mp4"
        guard FileManager.default.fileExists(atPath: media) else { throw XCTSkip("Generate offline media first") }
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        let arguments = ["--family-preview", "--family-test-store", UUID().uuidString,
                         "--family-probe-clock", "--family-probe-media", media]
        var lastActual: Int64 = 0
        for phase in 0..<2 {
            app.launchArguments = arguments + (phase == 0 ? [] : ["--family-clock-existing"])
            app.launch()
            let result = app.staticTexts["family-clock-playback-result"]
            XCTAssertTrue(result.waitForExistence(timeout: 40))
            let prefix = "CLOCK PLAYBACK PASSED "
            XCTAssertTrue(result.label.hasPrefix(prefix), result.label)
            let json = Data(result.label.dropFirst(prefix.count).utf8)
            let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            let before = try XCTUnwrap(values["before"] as? NSNumber).int64Value
            let after = try XCTUnwrap(values["after"] as? NSNumber).int64Value
            XCTAssertEqual(before, lastActual, "process relaunch must retain billed usage")
            XCTAssertGreaterThan(after, before)
            XCTAssertEqual((values["pausedDelta"] as? NSNumber)?.int64Value, 0)
            XCTAssertEqual((values["frozen"] as? NSNumber)?.int64Value, 0)
            XCTAssertEqual(values["clockTrusted"] as? Bool, true)
            lastActual = after
            let evidence = XCTAttachment(string: result.label)
            evidence.name = phase == 0 ? "Clock first playback and pause" : "Clock relaunch and preserved usage"
            evidence.lifetime = .keepAlways
            add(evidence)
            app.terminate()
        }
    }

    func testLegacyClockRecoveryFromPlaybackRebuildsPlayer() throws {
        let store = try XCTUnwrap(ProcessInfo.processInfo.environment["FAMILY_CLOCK_LEGACY_STORE"],
                                  "Prepare the isolated legacy clock fixture before running this test")
        XCTAssertNotNil(UUID(uuidString: store))
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", store,
                               "--family-probe-clock-recovery", "--family-probe-media", "/tmp/ATVFamilyProbe.mp4"]
        app.launch()
        let recovery = app.buttons["family-clock-parent-retry"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: recovery)
        waitForExpectations(timeout: 5)
        // The default action must work with one Select, without moving focus
        // out of a revoked AVKit transport or traversing more confirmation pages.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["家长验证"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(recovery.waitForExistence(timeout: 10), "cancelling PIN must restore a usable recovery entry")
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: recovery)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["家长验证"].waitForExistence(timeout: 10))
        for digit in [6, 4, 7, 2, 9, 1] {
            let key = app.cells["family-pin-\(digit)"]
            XCTAssertTrue(key.waitForExistence(timeout: 5))
            for _ in 0..<12 {
                if key.hasFocus { break }
                let current = app.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
                XCTAssertTrue(current.exists)
                if abs(current.frame.midX - key.frame.midX) > 10 {
                    XCUIRemote.shared.press(current.frame.midX < key.frame.midX ? .right : .left)
                } else {
                    XCUIRemote.shared.press(current.frame.midY < key.frame.midY ? .down : .up)
                }
            }
            XCTAssertTrue(key.hasFocus)
            XCUIRemote.shared.press(.select)
        }
        let evidence = app.staticTexts["family-clock-recovery-played"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 20), "one PIN must resume via a fresh player automatically")
        XCTAssertFalse(app.buttons["family-clock-confirm"].exists)
        XCTAssertFalse(app.buttons["family-clock-retry"].exists)
        XCTAssertFalse(app.staticTexts["家长验证"].exists)
        XCTAssertTrue(evidence.label.hasPrefix("CLOCK RECOVERY PLAYED"), evidence.label)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Legacy clock recovery creates new billed player"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testChildRestShowsCountdownBalanceAndExplicitResume() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString,
                               "--family-probe-rest-status", "--family-probe-media", "/tmp/ATVFamilyProbe.mp4"]
        app.launch()
        let rest = app.staticTexts["family-child-rest"]
        XCTAssertTrue(rest.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["休息一下吧"].exists)
        let balance = app.staticTexts["family-child-remaining"]
        XCTAssertTrue(balance.label.hasPrefix("今天还能看"))
        let originalBalance = balance.label
        let countdown = rest.label
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Child rest countdown and remaining daily balance"
        shot.lifetime = .keepAlways
        add(shot)
        expectation(for: NSPredicate(format: "label != %@", countdown), evaluatedWith: rest)
        waitForExpectations(timeout: 4)
        XCTAssertEqual(balance.label, originalBalance, "rest must not consume the viewing allowance")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请查看家庭管理")).firstMatch.exists)
        let resume = app.buttons["family-child-continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 35))
        XCTAssertTrue(resume.isEnabled)
        for _ in 0..<3 {
            if resume.hasFocus { break }
            XCUIRemote.shared.press(.left)
        }
        XCTAssertTrue(resume.hasFocus)
        XCUIRemote.shared.press(.select)
        let result = app.staticTexts["family-clock-recovery-played"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.label.hasPrefix("CLOCK RECOVERY PLAYED"), result.label)
        XCTAssertFalse(app.staticTexts["家长验证"].exists)
    }

    func testChildScheduleShowsNextWindowAndBalanceWithoutParentSettings() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString,
                               "--family-probe-schedule-status", "--family-probe-media", "/tmp/ATVFamilyProbe.mp4"]
        app.launch()
        let next = app.staticTexts["family-child-next-window"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        XCTAssertTrue(next.label.hasPrefix("下次观看时段："))
        XCTAssertTrue(app.staticTexts["family-child-remaining"].label.hasPrefix("今天还能看"))
        XCTAssertTrue(app.staticTexts["还没到观看时间"].exists)
        XCTAssertTrue(app.buttons["family-child-return"].exists)
        XCTAssertFalse(app.buttons["family-child-continue"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请查看家庭管理")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Child next viewing window and remaining balance"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testWeekendToggleMeansUnrestrictedScheduleNotNoWatching() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        setupParent(app)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["每天最多看多久"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        selectRow(app, "限制周末观看时段")
        XCTAssertEqual(app.cells["限制周末观看时段"].value as? String, "开 · 按下面时段")
        XCTAssertTrue(app.cells["周末开始"].exists)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.cells["限制周末观看时段"].value as? String, "关 · 不限制时段")
        selectRow(app, "完成")
        XCTAssertTrue(app.cells["第 1 步 · 添加孩子"].waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if app.cells["family-nav-观看时间"].hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(app.cells["连续看多久需要休息"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["连续看多久需要休息"].value as? String, "40 分钟")
        XCTAssertEqual(app.cells["每次休息多长时间"].value as? String, "10 分钟")
        XCTAssertEqual(app.cells["限制周末观看时段"].value as? String, "关 · 不限制时段")
    }

    func testOfflineMediaStopsAtFamilyContinuousLimit() throws {
        let media = "/tmp/ATVFamilyProbe.mp4"
        guard FileManager.default.fileExists(atPath: media) else {
            throw XCTSkip("Generate the synthetic offline media fixture first")
        }
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString,
                               "--family-probe-media", media]
        app.launch()
        let result = app.staticTexts["family-playback-probe-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 35))
        XCTAssertTrue(result.label.hasPrefix("PROBE PASSED"), result.label)
        let evidence = XCTAttachment(string: result.label)
        evidence.name = "Actual AVPlayer family ledger result"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testNativeSettingsNavigationAndOriginalRowStyle() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        let entry = app.cells["家长验证"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        print("NATIVE_LOCKED \(app.debugDescription)")
        for _ in 0..<3 {
            if entry.hasFocus { break }
            XCUIRemote.shared.press(.right)
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创建六位家长 PIN"].waitForExistence(timeout: 5))
        let first = app.cells["family-pin-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: first)
        waitForExpectations(timeout: 5)
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.staticTexts["请再次输入相同 PIN。"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        let overview = app.cells["family-nav-家庭概览"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native family settings overview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("NATIVE_UNLOCKED \(app.debugDescription)")
        // Left rail focus switches category without an extra fullscreen form.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["添加孩子"].waitForExistence(timeout: 5))
        let profiles = XCTAttachment(screenshot: app.screenshot())
        profiles.name = "Native profile settings"
        profiles.lifetime = .keepAlways
        add(profiles)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["每天最多看多久"].waitForExistence(timeout: 5))
        let watch = XCTAttachment(screenshot: app.screenshot())
        watch.name = "Native watch settings"
        watch.lifetime = .keepAlways
        add(watch)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.cells["每天最多看多久"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["120 分钟"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.cells["每天最多看多久"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["每天最多看多久"].value as? String, "120 分钟")
        for _ in 0..<24 {
            if app.cells["完成"].exists && app.cells["完成"].hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(app.cells["完成"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["剩余可用"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.cells["家长验证"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.cells["family-nav-孩子管理"].exists)
    }

    func testNativeSettingsSaveReportsAndSupport() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.cells["家长验证"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创建六位家长 PIN"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["family-pin-1"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.staticTexts["请再次输入相同 PIN。"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
        // First-run guidance appears before any child exists.
        XCTAssertTrue(app.cells["第 1 步 · 添加孩子"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["每天最多看多久"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["每天最多看多久"].value as? String, "120 分钟")
        // Ordinary change: open the choice, pick 135, save — all without PIN.
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["135 分钟"].waitForExistence(timeout: 5))
        for _ in 0..<24 {
            if app.cells["135 分钟"].exists && app.cells["135 分钟"].hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(app.cells["135 分钟"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["每天最多看多久"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["每天最多看多久"].value as? String, "135 分钟")
        selectRow(app, "完成")
        XCTAssertTrue(app.cells["第 1 步 · 添加孩子"].waitForExistence(timeout: 10))
        let watchCategory = app.cells["family-nav-观看时间"]
        for _ in 0..<4 {
            if watchCategory.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(app.cells["每天最多看多久"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["每天最多看多久"].value as? String, "135 分钟", "must be reloaded from persisted configuration")
        // Rail focus follows selection; step to 学习奖励 and back to confirm.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["开启答题奖励"].waitForExistence(timeout: 5))
        let quizScreenshot = XCTAttachment(screenshot: app.screenshot())
        quizScreenshot.name = "Native quiz rules"
        quizScreenshot.lifetime = .keepAlways
        add(quizScreenshot)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["family-nav-使用报告"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        for _ in 0..<3 {
            if app.cells["验证并读取报告"].hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCUIRemote.shared.press(.select)
        // Session reuse: the report reads without any PIN sheet.
        XCTAssertFalse(app.staticTexts["家长验证"].exists)
        XCTAssertTrue(app.cells["按日期查看"].waitForExistence(timeout: 10))
        let reportScreenshot = XCTAttachment(screenshot: app.screenshot())
        reportScreenshot.name = "Native report summary"
        reportScreenshot.lifetime = .keepAlways
        add(reportScreenshot)
        XCUIRemote.shared.press(.left)
        for _ in 0..<8 {
            let support = app.cells["family-nav-关于与支持"]
            if support.exists && support.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCUIRemote.shared.press(.right)
        // Entering 关于与支持 shows the appreciation section immediately: no PIN,
        // no timer. The page is a dedicated scroll layout, not settings rows.
        let imageVisible = app.images["开发者赞赏码"].waitForExistence(timeout: 5)
        let unconfigured = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "此构建未配置微信赞赏码")).firstMatch.exists
        let privateNotice = app.staticTexts["支持项目持续更新"].exists
        XCTAssertTrue(imageVisible || privateNotice || unconfigured,
            "support page must show the code or the unconfigured notice")
        let supportScreenshot = XCTAttachment(screenshot: app.screenshot())
        supportScreenshot.name = "Native about and support"
        supportScreenshot.lifetime = .keepAlways
        add(supportScreenshot)
    }

    func testHighRiskOperationsStillRequirePIN() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.cells["家长验证"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创建六位家长 PIN"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["family-pin-1"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.staticTexts["请再次输入相同 PIN。"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
        // 临时调整 lives in the 更多管理 group of the rail.
        for _ in 0..<10 {
            let grants = app.cells["family-nav-临时调整"]
            if grants.exists && grants.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(app.cells["family-nav-临时调整"].hasFocus)
        XCUIRemote.shared.press(.right)
        for _ in 0..<3 {
            if app.cells["增加观看时间 · 15 分钟"].hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(app.cells["增加观看时间 · 15 分钟"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        // High-risk override: the PIN sheet MUST appear despite the live session.
        XCTAssertTrue(app.staticTexts["家长验证"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
    }

    func testSetupPINAndVerifyAgainWithRemote() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.cells["家长验证"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创建六位家长 PIN"].waitForExistence(timeout: 5))
        let one = app.cells["family-pin-1"]
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        XCTAssertTrue(one.hasFocus)
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.staticTexts["请再次输入相同 PIN。"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["family-nav-关于与支持"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.cells["家长验证"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.cells["family-nav-孩子管理"].exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["家长验证"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["family-pin-1"].hasFocus)
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
    }

    func testFamilyPreviewRequiresPINBeforeShowingProfilesOrSupport() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.cells["家长验证"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.cells["family-nav-孩子管理"].exists)
        XCTAssertFalse(app.cells["family-nav-关于与支持"].exists)
        let entry = app.cells["家长验证"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        let setup = app.staticTexts["创建六位家长 PIN"]
        let verify = app.staticTexts["家长验证"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5) || verify.exists)
        XCTAssertTrue(app.cells["family-pin-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["family-pin-取消"].exists)
        XCTAssertFalse(app.staticTexts["支持项目持续更新"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "PIN gate on tvOS simulator"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIRemote.shared.press(.menu)
    }

    // MARK: - P0 acceptance A + D: first-use closed loop

    /// 验收 A + D：添加孩子（只填昵称）→ 自动成为当前观看者 → 概览确认时间 →
    /// 开启儿童模式不再要 PIN → 关闭儿童模式必须重新输 PIN。
    func testFirstUseAddsChildAutoSelectsAndEnablesChildModeWithoutPIN() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        let entry = app.cells["家长验证"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: entry)
        waitForExpectations(timeout: 10)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创建六位家长 PIN"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.staticTexts["请再次输入相同 PIN。"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["第 1 步 · 添加孩子"].waitForExistence(timeout: 5))
        // Step 1 lands on 孩子管理 (real navigation, not a dead notice).
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.cells["第 1 步 · 添加孩子"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["family-nav-孩子管理"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["添加孩子"].waitForExistence(timeout: 5))
        // Editor first layer: nickname/avatar/grade/enabled + daily quota only.
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["添加孩子"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["孩子昵称"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["年级"].exists)
        XCTAssertTrue(app.cells["个人每日额度"].exists)
        // No manual academic year, semester, textbook or chapter rows any more.
        XCTAssertFalse(app.cells["学年"].exists)
        XCTAssertFalse(app.cells["学年与学期"].exists)
        XCTAssertFalse(app.cells["学制"].exists)
        XCTAssertFalse(app.cells["科目、教材与已学章节"].exists)
        // Subjects stay optional until the parent ticks them.
        XCTAssertTrue(app.cells["选择科目"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["选择科目"].value as? String, "未启用")
        // Type only the nickname.
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.cells["孩子昵称"].hasFocus)
        XCUIRemote.shared.press(.select)
        // The return keystroke commits the dialog directly and focus lands
        // back on the editor rows.
        typeIntoAlertField(app, "小明")
        XCTAssertEqual(app.cells["孩子昵称"].value as? String, "小明")
        sleep(1)
        // The nickname save is automatic with the live session: no PIN sheet,
        // then 完成 returns to the child list.
        selectRow(app, "完成")
        XCTAssertFalse(app.staticTexts["家长验证"].exists, "saving a child must not ask for PIN")
        XCTAssertTrue(app.cells["小明 · 1"].waitForExistence(timeout: 10))
        let viewerValue = app.cells["小明 · 1"].value as? String
        XCTAssertTrue(viewerValue?.contains("✓") == true,
                      "first enabled child must auto-become the current viewer: \(viewerValue ?? "nil")")
        // Overview now shows the real state instead of the guide.
        XCUIRemote.shared.press(.left)
        for _ in 0..<3 {
            if app.cells["family-nav-家庭概览"].hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.cells["当前观看者"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["当前观看者"].value as? String, "小明")
        // D: the family time section is readable at a glance.
        XCTAssertTrue(app.cells["剩余可用"].exists)
        XCTAssertTrue(app.cells["今天已观看"].exists)
        XCTAssertTrue(app.cells["连续观看"].exists)
        // Enabling child mode uses the live session: no extra PIN.
        XCTAssertTrue(app.cells["儿童模式"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["儿童模式"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells["儿童模式"].value as? String, "已开启")
        XCTAssertFalse(app.staticTexts["家长验证"].exists, "enable must not require an extra PIN")
        let enabled = XCTAttachment(screenshot: app.screenshot())
        enabled.name = "Child mode enabled without extra PIN"
        enabled.lifetime = .keepAlways
        add(enabled)
        // Disabling stays a high-risk operation: a fresh PIN is mandatory.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["家长验证"].waitForExistence(timeout: 5),
                      "disable must always require a fresh PIN")
        XCUIRemote.shared.press(.menu)
    }

    /// 验收 C：第二个孩子不会覆盖当前观看者；从概览可一键切换，历史保留。
    /// The long-list picker must open on the stored value, not 00:00/15 分钟.
    func testChoicePageFocusesCurrentValue() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        setupParent(app)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["添加孩子"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        selectRow(app, "添加孩子")
        XCTAssertTrue(app.cells["孩子昵称"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        typeIntoAlertField(app, "焦点测试")
        selectRow(app, "完成")
        XCTAssertTrue(app.cells["焦点测试 · 1"].waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if app.cells["焦点测试 · 1"].hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(app.cells["焦点测试 · 1"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["昵称"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        selectRow(app, "编辑档案")
        XCTAssertTrue(app.cells["孩子昵称"].waitForExistence(timeout: 10))
        selectRow(app, "年级")
        let current = app.cells["4 年级"]
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertTrue(current.hasFocus, "choice page must start on the saved value")
        XCUIRemote.shared.press(.menu)
    }

    /// Disabling the only enabled child stops playback; it must ask first.
    func testDisablingLastChildRequiresConfirmation() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        setupParent(app)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["添加孩子"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        selectRow(app, "添加孩子")
        XCTAssertTrue(app.cells["孩子昵称"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        typeIntoAlertField(app, "停用测试")
        selectRow(app, "完成")
        XCTAssertTrue(app.cells["停用测试 · 1"].waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if app.cells["停用测试 · 1"].hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(app.cells["停用测试 · 1"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["昵称"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        selectRow(app, "编辑档案")
        XCTAssertTrue(app.cells["启用档案"].waitForExistence(timeout: 10))
        selectRow(app, "启用档案")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "停用这个孩子")).firstMatch.exists)
        let cancel = alert.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(cancel.hasFocus, "the safe action must be focused")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["启用档案"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["启用档案"].value as? String, "开",
                       "cancelling must keep the child enabled")
        XCUIRemote.shared.press(.menu)
    }

    /// Schedule times are picked as hour then minute; the picker starts on the
    /// current time and applies the new value immediately.
    func testClockPickerStartsAtCurrentTimeAndSaves() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        setupParent(app)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["限制工作日观看时段"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        selectRow(app, "限制工作日观看时段")
        XCTAssertTrue(app.cells["工作日开始"].waitForExistence(timeout: 10))
        selectRow(app, "工作日开始")
        let currentHour = app.cells["08 时"]
        XCTAssertTrue(currentHour.waitForExistence(timeout: 10))
        XCTAssertTrue(currentHour.hasFocus, "time picker must start on the saved hour")
        selectRow(app, "09 时")
        selectRow(app, "30 分", maxSteps: 40)
        XCUIRemote.shared.press(.menu)
        let start = app.cells["工作日开始"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.value as? String, "09:30")
    }

    func testSubjectChecklistSavesImmediatelyAndPersists() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        setupParent(app)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["添加孩子"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        selectRow(app, "添加孩子")
        XCTAssertTrue(app.cells["孩子昵称"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["选择科目"].value as? String, "未启用")
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        typeIntoAlertField(app, "科目测试")
        selectRow(app, "完成")
        XCTAssertTrue(app.cells["科目测试 · 1"].waitForExistence(timeout: 10))
        // Focus after the pop can land on the management rows; walk back up to
        // the saved child instead of assuming the list remembers it.
        for _ in 0..<4 {
            if app.cells["科目测试 · 1"].hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(app.cells["科目测试 · 1"].hasFocus)
        // Open the saved child, then its editor. The list row opens a detail
        // page; 编辑档案 is the single entry to the auto-saving editor.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells["昵称"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        selectRow(app, "编辑档案")
        XCTAssertTrue(app.cells["选择科目"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        selectRow(app, "选择科目")
        XCTAssertTrue(app.cells["数学"].waitForExistence(timeout: 5), "grade 4 bank must offer subjects")
        XCTAssertEqual(app.cells["数学"].value as? String, "关")
        XCUIRemote.shared.press(.select)
        expectation(for: NSPredicate(format: "value == %@", "开"), evaluatedWith: app.cells["数学"])
        waitForExpectations(timeout: 10)
        XCUIRemote.shared.press(.menu)
        let label = app.cells["选择科目"]
        expectation(for: NSPredicate(format: "value == %@", "1 科 · 全章节"), evaluatedWith: label)
        waitForExpectations(timeout: 10)
        selectRow(app, "完成")
        // Reopen from the refreshed child record: the tick was written, not
        // just painted in the local draft.
        XCTAssertTrue(app.cells["编辑档案"].waitForExistence(timeout: 10))
        selectRow(app, "编辑档案")
        XCTAssertTrue(app.cells["选择科目"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.cells["选择科目"].value as? String, "1 科 · 全章节")
        XCUIRemote.shared.press(.right)
        selectRow(app, "选择科目")
        XCTAssertTrue(app.cells["数学"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["数学"].value as? String, "开")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Subject checklist saved without a save button"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCUIRemote.shared.press(.menu)
    }

    func testSecondChildDoesNotOverrideViewerAndOverviewCanSwitch() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        let entry2 = app.cells["家长验证"]
        XCTAssertTrue(entry2.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: entry2)
        waitForExpectations(timeout: 10)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创建六位家长 PIN"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.staticTexts["请再次输入相同 PIN。"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["添加孩子"].waitForExistence(timeout: 5))
        for (offset, nickname) in ["小明", "小红"].enumerated() {
            // Enter content from the rail; after the first save the focus is on
            // the profile list, so walk down to 添加孩子 instead of assuming it.
            XCUIRemote.shared.press(.right)
            for _ in 0..<8 {
                if app.cells["添加孩子"].hasFocus { break }
                XCUIRemote.shared.press(.down)
            }
            XCTAssertTrue(app.cells["添加孩子"].hasFocus)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.cells["孩子昵称"].waitForExistence(timeout: 5))
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(app.cells["孩子昵称"].hasFocus)
            XCUIRemote.shared.press(.select)
            typeIntoAlertField(app, nickname)
            selectRow(app, "完成")
            sleep(2)
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: "/tmp/after-save-\(nickname).png"))
            XCTAssertTrue(app.cells["\(nickname) · \(offset + 1)"].waitForExistence(timeout: 10))
            XCUIRemote.shared.press(.left)
            for _ in 0..<3 {
                if app.cells["family-nav-孩子管理"].hasFocus { break }
                XCUIRemote.shared.press(.up)
            }
        }
        // Adding the second child must not silently change the current viewer.
        for _ in 0..<3 {
            if app.cells["family-nav-家庭概览"].hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.cells["当前观看者"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells["当前观看者"].value as? String, "小明")
        XCTAssertTrue(app.cells["切换当前观看者"].exists)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.cells["切换当前观看者"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["小红"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        // The switch refreshes asynchronously: wait for the value to change,
        // not just for the row to exist (it never disappears).
        let viewerRow = app.cells["当前观看者"]
        XCTAssertTrue(viewerRow.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "小红"), evaluatedWith: viewerRow)
        waitForExpectations(timeout: 10)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/after-switch.png"))
        XCTAssertEqual(app.cells["儿童模式"].value as? String, "未开启")
        let switched = XCTAttachment(screenshot: app.screenshot())
        switched.name = "Viewer switched to second child from overview"
        switched.lifetime = .keepAlways
        add(switched)
    }

    /// 验收 F（公共构建侧）：模拟器构建不含私人赞赏码，支持页必须显示
    /// 未配置提示而不是空白或占位图；私人真机构建的原图检查在设备走查记录。
    func testPublicBuildSupportPageShowsUnconfiguredNotice() {
        let app = XCUIApplication(bundleIdentifier: "com.etan.tv.BilibiliLive")
        app.launchArguments = ["--family-preview", "--family-test-store", UUID().uuidString]
        app.launch()
        let entry3 = app.cells["家长验证"]
        XCTAssertTrue(entry3.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: entry3)
        waitForExpectations(timeout: 10)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创建六位家长 PIN"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.staticTexts["请再次输入相同 PIN。"].waitForExistence(timeout: 5))
        for _ in 0..<6 { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(app.cells["family-nav-家庭概览"].waitForExistence(timeout: 10))
        for _ in 0..<10 {
            let support = app.cells["family-nav-关于与支持"]
            if support.exists && support.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCUIRemote.shared.press(.right)
        // Public build: the dedicated support page explains the unconfigured
        // state. (The image view element exists even with a nil image, so the
        // private-image check is done on the private build/device instead.)
        XCTAssertTrue(app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "此构建未配置微信赞赏码"))
            .firstMatch.waitForExistence(timeout: 5),
            "support page must explain the unconfigured state in public builds")
        let notice = XCTAttachment(screenshot: app.screenshot())
        notice.name = "Public build support page notice"
        notice.lifetime = .keepAlways
        add(notice)
    }
}

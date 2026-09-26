import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AgentCore

@Suite struct AgentTests {
    @Test func completesWhenPilotIsDone() async throws {
        let device = FakeDevice()
        let pilot = ScriptedPilot(.tap(.element(1)), .type("hello", replacing: false), .done(summary: "Sent"))
        let agent = Agent(device: device, pilot: pilot, settle: .zero)

        let outcome = try await agent.run("Send hello")

        #expect(outcome == .completed(summary: "Sent"))
        #expect(await device.gestures == [.tap(Point(x: 0.5, y: 0.5)), .type("hello")])
    }

    @Test func feedsUnknownElementBackToPilot() async throws {
        let pilot = ScriptedPilot(.tap(.element(99)), .giveUp(reason: "stuck"))
        let agent = Agent(device: FakeDevice(), pilot: pilot, settle: .zero)

        let outcome = try await agent.run("Tap something")

        #expect(outcome == .abandoned(reason: "stuck"))
        #expect(await pilot.lastHistory.first?.failure == ResolutionError.unknownElement(99).description)
    }

    @Test func throwsUnrecoverableDeviceErrors() async {
        let agent = Agent(device: FakeDevice(failure: .tunnelUnavailable), pilot: ScriptedPilot(.tap(.element(1))), settle: .zero)

        await #expect(throws: DeviceError.tunnelUnavailable) {
            try await agent.run("Anything")
        }
    }

    @Test func continuesAfterABadDecision() async throws {
        let pilot = RecoveringPilot()
        let outcome = try await Agent(device: FakeDevice(), pilot: pilot, settle: .zero).run("Open Weather")
        #expect(outcome == .completed(summary: "recovered"))
        #expect(await pilot.calls == 2)
    }

    @Test func stopsAtStepLimit() async throws {
        let pilot = ScriptedPilot(repeating: .wait(seconds: 0))
        let outcome = try await Agent(device: FakeDevice(), pilot: pilot, maxSteps: 3, settle: .zero).run("Loop")

        #expect(outcome == .outOfSteps)
    }

    @Test func flagsActionsThatChangeNothing() async throws {
        let pilot = ScriptedPilot(.tap(.element(1)), .giveUp(reason: "stuck"))
        _ = try await Agent(device: FakeDevice(), pilot: pilot, settle: .zero).run("Tap OK")

        #expect(await pilot.lastHistory.first?.failure == "The screen did not change.")
    }

    @Test func skipsThirdIdenticalAction() async throws {
        let device = FakeDevice(changesEachStep: true)
        let pilot = ScriptedPilot(.key(.tab), .key(.tab), .key(.tab), .giveUp(reason: "stuck"))
        _ = try await Agent(device: device, pilot: pilot, settle: .zero).run("Type")

        #expect(await device.gestures == [.key(.tab), .key(.tab)])
        #expect(await pilot.lastHistory.last?.failure?.hasPrefix("Skipped") == true)
    }

    @Test func performsPreparationBeforeFirstObservation() async throws {
        let device = FakeDevice()
        let agent = Agent(device: device, pilot: ScriptedPilot(.done(summary: "ok")), settle: .zero, preparation: [.press(.home)])

        _ = try await agent.run("Anything")

        #expect(await device.gestures == [.press(.home)])
    }

    @Test func typesTextOnlyOnce() async throws {
        let device = FakeDevice()
        let pilot = ScriptedPilot(.type("hello", replacing: false), .type("hello", replacing: false), .done(summary: "typed"))
        _ = try await Agent(device: device, pilot: pilot, settle: .zero).run("Type hello")

        #expect(await device.gestures == [.type("hello")])
        #expect(await pilot.lastHistory.first?.failure == nil, "Typing is never reported as 'screen did not change'")
        #expect(await pilot.lastHistory.last?.failure?.hasPrefix("Skipped: this text was already typed") == true)
    }

    @Test func replacingSelectsAllDeletesThenTypes() async throws {
        let device = FakeDevice()
        let pilot = ScriptedPilot(.type("Wi-Fi", replacing: true), .done(summary: "typed"))
        _ = try await Agent(device: device, pilot: pilot, settle: .zero).run("Replace field text")

        #expect(await device.gestures == [.selectAll, .key(.delete), .type("Wi-Fi")])
    }

    @Test func replacingAfterPlainTypeIsNotSkipped() async throws {
        let device = FakeDevice(changesEachStep: true)
        let pilot = ScriptedPilot(.type("x", replacing: false), .type("x", replacing: true), .done(summary: "typed"))
        _ = try await Agent(device: device, pilot: pilot, settle: .zero).run("Type then replace")

        #expect(await device.gestures == [.type("x"), .selectAll, .key(.delete), .type("x")])
        #expect(await pilot.lastHistory.allSatisfy { $0.failure == nil })
    }

    @Test func flagsCircling() async throws {
        let pilot = ScriptedPilot(.scroll(.down), .scroll(.up), .scroll(.down), .scroll(.up), .giveUp(reason: "lost"))
        _ = try await Agent(device: AlternatingDevice(), pilot: pilot, settle: .zero).run("Find Settings")

        let failures = await pilot.lastHistory.compactMap(\.failure)
        #expect(failures.contains { $0.hasPrefix("You are going in circles") })
    }

    @Test(arguments: Direction.allCases)
    func scrollMovesFingerAgainstDirection(_ direction: Direction) throws {
        guard case .swipe(let start, let end, _) = Gesture.swipe(direction, in: .fullScreen) else {
            Issue.record("Expected a swipe")
            return
        }
        switch direction {
        case .down: #expect(start.y > end.y)
        case .up: #expect(start.y < end.y)
        case .right: #expect(start.x > end.x)
        case .left: #expect(start.x < end.x)
        }
    }

    @Test func outlineUsesGridCoordinates() {
        let element = Element(id: 3, role: .button, label: "Send", frame: Rect(x: 0.8, y: 0.9, width: 0.1, height: 0.02))
        #expect(element.outline == #"[3] button "Send" @(850,910)"#)
    }

    @Test func outlineOmitsElementsWithoutMeaning() {
        let blank = Element(id: 9, role: .other, label: "", frame: .fullScreen)
        let screen = Screen(screenshot: .blank(width: 1, height: 1), elements: [blank])
        #expect(screen.outline() == "screen=1x1 elements=0/0")
    }

    @Test func outlineShowsValueTraitsAndTruncation() {
        let field = Element(id: 4, role: .textField, label: "Message", value: "hi", frame: .fullScreen, traits: [.focused, .disabled])
        let screen = Screen(screenshot: Screenshot.blank(width: 10, height: 20), elements: [field, field])

        #expect(screen.outline(limit: 1) == """
            screen=10x20 elements=1/2
            [4] textField "Message" = "hi" @(500,500) disabled focused
            …+1 more
            """)
    }
}

private actor FakeDevice: Device {
    private(set) var gestures: [Gesture] = []
    private let failure: DeviceError?
    private let changesEachStep: Bool
    private var observations = 0

    init(failure: DeviceError? = nil, changesEachStep: Bool = false) {
        self.failure = failure
        self.changesEachStep = changesEachStep
    }

    func observe() throws(DeviceError) -> Screen {
        observations += 1
        return Screen(
            screenshot: Screenshot.blank(width: 1, height: 1),
            elements: [Element(id: 1, role: .button, label: changesEachStep ? "OK \(observations)" : "OK", frame: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))]
        )
    }

    func perform(_ gesture: Gesture) throws(DeviceError) {
        if let failure { throw failure }
        gestures.append(gesture)
    }
}

private actor ScriptedPilot: Pilot {
    private var script: [Action]
    private let fallback: Action?
    private(set) var lastHistory: [Turn] = []
    private(set) var apps: [FrontmostApp?] = []

    init(_ script: Action...) { self.script = script; fallback = nil }
    init(repeating action: Action) { script = []; fallback = action }

    func decide(_ step: Step) -> Decision {
        lastHistory = step.history
        apps.append(step.app)
        let action = script.isEmpty ? fallback! : script.removeFirst()
        return Decision(action: action)
    }
}

private struct ParseError: Error, LocalizedError {
    var errorDescription: String? { "missing app" }
}

private actor RecoveringPilot: Pilot {
    var calls = 0
    func decide(_ step: Step) async throws -> Decision {
        calls += 1
        if calls == 1 { throw ParseError() }
        return Decision(thought: "ok", action: .done(summary: "recovered"))
    }
}

extension Screenshot {
    static func blank(width: Int, height: Int) -> Screenshot {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return Screenshot(image: context.makeImage()!)
    }
}

@Suite struct ScreenshotTests {
    @Test func jpegDownscalesToLongestEdge() async throws {
        let data = try #require(await Screenshot.blank(width: 400, height: 800).jpeg(maxDimension: 200))
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })

        #expect((image.width, image.height) == (100, 200))
    }
}

@Suite struct PromptingTests {
    @Test(arguments: [
        (Action.tap(.element(3)), "tap [3]"),
        (.tap(.point(Point(grid: 500, 420))), "tap (500,420)"),
        (.scroll(.down, in: .element(5)), "scroll down in [5]"),
        (.drag(from: .element(3), to: .point(Point(grid: 100, 200))), "drag [3]->(100,200)"),
        (.type("hi", replacing: false), #"type "hi""#),
        (.type("hi", replacing: true), #"type "hi" replacing"#),
        (.wait(seconds: 1.5), "wait 1.5s"),
    ])
    func actionsReadCompactly(_ action: Action, _ expected: String) {
        #expect(action.description == expected)
    }

    @Test func historyKeepsTurnNumbersWhenTruncated() {
        let turns = (1...4).map { Turn(decision: Decision(action: .wait(seconds: Double($0)))) }
        let step = Step(goal: "g", screen: Screen(screenshot: .blank(width: 1, height: 1)), history: turns)

        #expect(step.historyOutline(limit: 2) == "3. wait 3s\n4. wait 4s")

        let thoughtful = Step(goal: "g", screen: step.screen, history: [Turn(decision: Decision(thought: "Next: open Settings", action: .press(.home)))])
        #expect(thoughtful.historyOutline() == "1. press home — Next: open Settings")
        #expect(Step(goal: "g", screen: step.screen).historyOutline() == "(none yet)")
    }
}

@Suite struct DragResolutionTests {
    let screen = Screen(
        screenshot: .blank(width: 1, height: 1),
        elements: [Element(id: 3, role: .slider, label: "Volume", frame: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))]
    )

    @Test func dragResolvesBothTargetsToSwipeEndpoints() throws {
        let gesture = try Action.drag(from: .element(3), to: .point(Point(grid: 800, 500))).gesture(on: screen)
        #expect(gesture == .swipe(from: Point(x: 0.5, y: 0.5), to: Point(grid: 800, 500)))
    }

    @Test func dragFailsOnUnknownElement() {
        let action = Action.drag(from: .element(99), to: .point(Point(grid: 800, 500)))
        #expect(throws: ResolutionError.unknownElement(99)) { try action.gesture(on: screen) }
    }
}

@Suite struct KeepTests {
    @Test(arguments: [
        ("Did: tapped Expect: list Next: read\nKeep: code 42", "code 42"),
        ("Keep: first\nKeep: second", "second"),
        ("Keep:   \nKeep: kept", "kept"),
        ("no keep here", nil),
        ("Keep:   ", nil),
    ])
    func parsesLatestNonEmptyKeepLine(_ thought: String, _ expected: String?) {
        #expect(Decision(thought: thought, action: .wait(seconds: 0)).keepFacts == expected)
    }

    @Test func capsKeepFactsAt200Characters() {
        let long = String(repeating: "x", count: 300)
        let facts = Decision(thought: "Keep: \(long)", action: .wait(seconds: 0)).keepFacts
        #expect(facts == String(repeating: "x", count: 200))
    }

    @Test func briefShowsRememberedLineOnlyWhenSet() {
        let screen = Screen(screenshot: .blank(width: 1, height: 1))
        #expect(Step(goal: "g", screen: screen).brief().contains("Remembered:") == false)
        #expect(Step(goal: "g", screen: screen, remembered: "code 42").brief().contains("Remembered: code 42"))
    }

    @Test func agentCarriesKeepLineToNextBrief() async throws {
        let pilot = BriefCapturingPilot(decisions: [
            Decision(thought: "Next: tap ok\nKeep: code 42", action: .tap(.element(1))),
            Decision(thought: "Next: finish", action: .done(summary: "ok")),
        ])
        _ = try await Agent(device: FakeDevice(), pilot: pilot, settle: .zero).run("Remember")

        let briefs = await pilot.briefs
        #expect(briefs.count == 2)
        #expect(briefs[0].contains("Remembered:") == false)
        #expect(briefs[1].contains("Remembered: code 42"))
    }
}

private actor BriefCapturingPilot: Pilot {
    private var decisions: [Decision]
    private(set) var briefs: [String] = []

    init(decisions: [Decision]) { self.decisions = decisions }

    func decide(_ step: Step) -> Decision {
        briefs.append(step.brief())
        return decisions.removeFirst()
    }
}

@Suite struct FallbackTests {
    struct Failing: Pilot {
        let error: any Error
        func decide(_ step: Step) async throws -> Decision { throw error }
    }

    struct Fixed: Pilot {
        let action: Action
        func decide(_ step: Step) async throws -> Decision { Decision(action: action) }
    }

    let step = Step(goal: "g", screen: Screen(screenshot: .blank(width: 1, height: 1)))

    @Test func usesBackupWhenPrimaryFails() async throws {
        let pilot = Failing(error: DeviceError.timedOut).fallback(to: Fixed(action: .press(.home)))
        #expect(try await pilot.decide(step).action == .press(.home))
    }

    @Test func prefersPrimary() async throws {
        let pilot = Fixed(action: .type("a", replacing: false)).fallback(to: Fixed(action: .type("b", replacing: false)))
        #expect(try await pilot.decide(step).action == .type("a", replacing: false))
    }

    @Test func doesNotFallBackOnCancellation() async {
        let pilot = Failing(error: CancellationError()).fallback(to: Fixed(action: .press(.home)))
        await #expect(throws: CancellationError.self) { try await pilot.decide(step) }
    }
}

@Suite struct MarkingTests {
    @Test func outlinesElementsWithoutChangingSize() async throws {
        let element = Element(id: 7, role: .button, label: "OK", frame: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let screen = Screen(screenshot: .blank(width: 200, height: 400), elements: [element])

        let marked = await screen.markedScreenshot()

        #expect((marked.width, marked.height) == (200, 400))
        #expect(marked.pixel(x: 50, y: 250) != screen.screenshot.pixel(x: 50, y: 250), "The box's left edge is stroked")
        #expect(marked.pixel(x: 100, y: 200) == screen.screenshot.pixel(x: 100, y: 200), "The box's interior is untouched")
    }
}

private extension Screenshot {
    func pixel(x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(height - 1 - y), width: width, height: height))
        return bytes
    }
}

@Suite struct AppResolutionTests {
    let apps = [
        InstalledApp(name: "Settings", bundleID: "com.apple.Preferences"),
        InstalledApp(name: "Safari", bundleID: "com.apple.mobilesafari"),
        InstalledApp(name: "Shortcuts", bundleID: "com.apple.shortcuts"),
    ]

    @Test(arguments: [
        ("Settings", "com.apple.Preferences"),
        ("safari", "com.apple.mobilesafari"),
        ("com.apple.shortcuts", "com.apple.shortcuts"),
        ("Short", "com.apple.shortcuts"),
    ])
    func resolvesNamesAndIdentifiers(_ query: String, _ bundleID: String) throws {
        #expect(try apps.bundleID(for: query) == bundleID)
    }

    @Test func ambiguousOrUnknownNamesFailWithSuggestions() {
        #expect(throws: ResolutionError.unknownApp("S", similar: ["Settings", "Safari", "Shortcuts"])) { try apps.bundleID(for: "S") }
        #expect(throws: ResolutionError.unknownApp("Setting App", similar: ["Settings"])) { try apps.bundleID(for: "Setting App") }
    }

    @Test func passesThroughWithoutAList() throws {
        #expect(try [InstalledApp]().bundleID(for: "com.example.app") == "com.example.app")
    }
}

/// Flips between two screens, the pattern of a pilot scrolling back and forth.
private actor AlternatingDevice: Device {
    private var flip = false

    func observe() throws(DeviceError) -> Screen {
        flip.toggle()
        let label = flip ? "Page A" : "Page B"
        return Screen(screenshot: .blank(width: 1, height: 1),
                      elements: [Element(id: 1, role: .text, label: label, frame: .fullScreen)])
    }

    func perform(_ gesture: Gesture) throws(DeviceError) {}
}

@Suite struct InlineKeepTests {
    @Test(arguments: [
        ("Did: opened. Next: tap [3]. Keep: code 4812", "code 4812"),
        ("Next: tap [3]\nkeep: Anna's flight is LH 401", "Anna's flight is LH 401"),
        ("Keep: old\nKeep: new", "new"),
    ])
    func findsInlineAndLatestKeep(_ thought: String, _ facts: String) {
        #expect(Decision(thought: thought, action: .press(.home)).keepFacts == facts)
    }

    @Test func ignoresEmptyKeep() {
        #expect(Decision(thought: "Next: go home. Keep:", action: .press(.home)).keepFacts == nil)
    }
}

@Suite struct MentionedAppTests {
    let apps = [
        InstalledApp(name: "Settings", bundleID: "com.apple.Preferences"),
        InstalledApp(name: "App Store", bundleID: "com.apple.AppStore"),
        InstalledApp(name: "Notes", bundleID: "com.apple.mobilenotes"),
    ]

    @Test func findsWholeWordAppNames() {
        #expect(apps.named(in: "Open settings, then check the App Store") == ["App Store", "Settings"])
        #expect(apps.named(in: "Write footnotes") == [], "Notes must match as a whole word")
    }

    @Test func briefNamesThemWithOpen() {
        let step = Step(goal: "g", screen: Screen(screenshot: .blank(width: 1, height: 1)), mentionedApps: ["Settings"])
        #expect(step.brief().contains(#"Apps in the goal: "Settings" (installed; reach them with open)"#))
    }
}

@Suite struct LocationTests {
    @Test func briefUsesLiveFrontmostApp() {
        let settings = FrontmostApp(name: "Settings", bundleID: "com.apple.Preferences")
        let home = FrontmostApp(name: "SpringBoard", bundleID: "com.apple.springboard")
        let step = Step(goal: "g", screen: Screen(screenshot: .blank(width: 1, height: 1)), app: settings)
        #expect(step.brief().contains("App: Settings"))
        #expect(!step.brief().contains("You are in"))
        #expect(Step(goal: "g", screen: step.screen, app: home).brief().contains("App: Home Screen"))
        let mixed = FrontmostApp(name: "springboard", bundleID: "COM.APPLE.SPRINGBOARD")
        #expect(Step(goal: "g", screen: step.screen, app: mixed).brief().contains("App: Home Screen"))
        let byName = FrontmostApp(name: "SpringBoard", bundleID: "")
        #expect(Step(goal: "g", screen: step.screen, app: byName).brief().contains("App: Home Screen"))
        let timer = FrontmostApp(name: "MobileTimer", bundleID: "com.apple.mobiletimer")
            .resolved(using: [InstalledApp(name: "Clock", bundleID: "com.apple.mobiletimer")])
        #expect(Step(goal: "g", screen: step.screen, app: timer).brief().contains("App: Clock"))
        #expect(!Step(goal: "g", screen: step.screen, app: timer).brief().contains("MobileTimer"))
        let clock = FrontmostApp(name: "Clock", bundleID: "com.apple.mobiletimer")
        let reached = Step(goal: "Open the Clock app, then finish. Do not change anything.", screen: step.screen, mentionedApps: ["Clock"], app: clock)
        #expect(reached.brief().contains("The Clock app is open now. If the goal was only to open it, choose done."))
        #expect(!Step(goal: "Open Clock", screen: step.screen, mentionedApps: ["Clock"], app: settings).brief().contains("is open now"))
    }

    @Test func autoFinishesPureOpenWhenThatAppIsFrontmost() async throws {
        let pilot = ExplodingPilot()
        let device = ClockAlreadyOpenDevice()
        let outcome = try await Agent(device: device, pilot: pilot, settle: .zero)
            .run("Open the Clock app, then finish. Do not change anything.")
        #expect(outcome == .completed(summary: "Opened Clock."))
        #expect(await pilot.decided == false)
    }

    @Test func autoFinishesMultiWordAppNames() {
        #expect(OpenGoal.isPureOpen("Open the App Store, then finish", app: "App Store"))
        #expect(OpenGoal.isPureOpen("Open Voice Memos", app: "Voice Memos"))
        #expect(!OpenGoal.isPureOpen("Open App Store and buy something", app: "App Store"))
    }

    @Test func doesNotAutoFinishWhenGoalAsksForMoreThanOpen() async throws {
        let pilot = ScriptedPilot(.giveUp(reason: "x"))
        let device = ClockAlreadyOpenDevice()
        let outcome = try await Agent(device: device, pilot: pilot, settle: .zero)
            .run("Open the Clock app and turn on the 5:35 AM alarm")
        #expect(outcome == .abandoned(reason: "x"))
        #expect(await pilot.apps.count == 1)
    }

    @Test func readsActualAppEveryStep() async throws {
        let pilot = ScriptedPilot(.open(app: "settings"), .press(.home), .giveUp(reason: "x"))
        let device = AppListingDevice()
        _ = try await Agent(device: device, pilot: pilot, settle: .zero, preparation: [.press(.home)]).run("Open Settings and show Wi-Fi")

        #expect(await pilot.apps == [
            FrontmostApp(name: "SpringBoard", bundleID: "com.apple.springboard"),
            FrontmostApp(name: "Settings", bundleID: "com.apple.Preferences"),
            FrontmostApp(name: "SpringBoard", bundleID: "com.apple.springboard"),
        ])
    }
}

private actor ExplodingPilot: Pilot {
    var decided = false
    func decide(_ step: Step) async throws -> Decision {
        decided = true
        Issue.record("pilot should not be asked when a pure open-goal is already reached")
        return Decision(thought: "x", action: .giveUp(reason: "x"))
    }
}

private actor ClockAlreadyOpenDevice: Device {
    func observe() throws(DeviceError) -> Screen {
        Screen(screenshot: .blank(width: 1, height: 1),
               elements: [Element(id: 1, role: .text, label: "World Clock", frame: .fullScreen)])
    }
    func perform(_ gesture: Gesture) throws(DeviceError) {}
    func installedApps() throws(DeviceError) -> [InstalledApp] {
        [InstalledApp(name: "Clock", bundleID: "com.apple.mobiletimer")]
    }
    func frontmostApp() throws(DeviceError) -> FrontmostApp? {
        FrontmostApp(name: "Clock", bundleID: "com.apple.mobiletimer")
    }
}

private actor AppListingDevice: Device {
    private var step = 0
    private var appIndex = 0
    func observe() throws(DeviceError) -> Screen {
        step += 1
        return Screen(screenshot: .blank(width: 1, height: 1),
                      elements: [Element(id: 1, role: .text, label: "Screen \(step)", frame: .fullScreen)])
    }
    func perform(_ gesture: Gesture) throws(DeviceError) {}
    func installedApps() throws(DeviceError) -> [InstalledApp] { [InstalledApp(name: "Settings", bundleID: "com.apple.Preferences")] }
    func frontmostApp() throws(DeviceError) -> FrontmostApp? {
        defer { appIndex += 1 }
        return [
            FrontmostApp(name: "SpringBoard", bundleID: "com.apple.springboard"),
            FrontmostApp(name: "Settings", bundleID: "com.apple.Preferences"),
            FrontmostApp(name: "SpringBoard", bundleID: "com.apple.springboard"),
        ][appIndex]
    }
}

@Suite struct TypedTextConfirmationTests {
    @Test func confirmsTypedTextOnNextScreen() async throws {
        let pilot = ScriptedPilot(.type("eating dinner", replacing: false), .giveUp(reason: "x"))
        _ = try await Agent(device: TypingDevice(), pilot: pilot, settle: .zero).run("Search")

        #expect(await pilot.lastHistory.first?.confirmation?.hasPrefix("typed, now on screen: [1]") == true)
    }
}

private actor TypingDevice: Device {
    private var typed = ""
    func observe() throws(DeviceError) -> Screen {
        Screen(screenshot: .blank(width: 1, height: 1),
               elements: [Element(id: 1, role: .textField, label: typed.isEmpty ? "Search" : "• \(typed.capitalized)", frame: .fullScreen)])
    }
    func perform(_ gesture: Gesture) throws(DeviceError) {
        if case .type(let text) = gesture { typed = text }
    }
}

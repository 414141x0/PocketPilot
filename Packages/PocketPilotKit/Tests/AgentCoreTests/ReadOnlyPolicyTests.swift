import Foundation
import Testing
@testable import AgentCore

@Suite struct ReadOnlyPolicyTests {
    private func makeDummyScreen(elements: [Element] = []) -> Screen {
        Screen(screenshot: .blank(width: 100, height: 100), elements: elements)
    }

    @Test func triggersOnPolicyFlagOrGoalKeywords() {
        #expect(RunPolicy.readOnly.isReadOnly(for: "Open Settings"))
        #expect(RunPolicy(readOnly: true).isReadOnly(for: ""))
        #expect(RunPolicy.default.isReadOnly(for: "Open the Clock app, then finish. Do not change anything."))
        #expect(RunPolicy.default.isReadOnly(for: "Open Clock, don't change anything"))
        #expect(RunPolicy.default.isReadOnly(for: "Open Clock, do not modify anything"))
        #expect(RunPolicy.default.isReadOnly(for: "Open Clock, don't modify alarms"))
        #expect(RunPolicy.default.isReadOnly(for: "Open Clock (read-only)"))
        #expect(RunPolicy.default.isReadOnly(for: "Open Clock read only please"))
        #expect(!RunPolicy.default.isReadOnly(for: "Open Clock and turn on the alarm"))
    }

    @Test func refusesUnconditionalMutations() {
        let screen = makeDummyScreen()

        #expect(ReadOnlyPolicy.refusal(for: .type("hello", replacing: false), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .type("hello", replacing: true), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .drag(from: .point(Point(x: 0, y: 0)), to: .point(Point(x: 1, y: 1))), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .key(.return), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .longPress(.element(1)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .press(.lock), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .press(.volumeUp), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .press(.volumeDown), on: screen) != nil)

        // Allowed navigation and completion
        #expect(ReadOnlyPolicy.refusal(for: .press(.home), on: screen) == nil)
        #expect(ReadOnlyPolicy.refusal(for: .open(app: "Clock"), on: screen) == nil)
        #expect(ReadOnlyPolicy.refusal(for: .wait(seconds: 1.0), on: screen) == nil)
        #expect(ReadOnlyPolicy.refusal(for: .done(summary: "Done"), on: screen) == nil)
        #expect(ReadOnlyPolicy.refusal(for: .giveUp(reason: "Stuck"), on: screen) == nil)
    }

    @Test func refusesTapsOnMutatingRoles() {
        let toggle = Element(id: 1, role: .toggle, label: "Alarm 7:00 AM", frame: Rect(x: 0.8, y: 0.2, width: 0.15, height: 0.05))
        let textField = Element(id: 2, role: .textField, label: "Label", frame: Rect(x: 0.2, y: 0.3, width: 0.6, height: 0.05))
        let key = Element(id: 3, role: .keyboardKey, label: "A", frame: Rect(x: 0.1, y: 0.7, width: 0.08, height: 0.05))
        let slider = Element(id: 4, role: .slider, label: "Volume", frame: Rect(x: 0.1, y: 0.5, width: 0.8, height: 0.05))
        let safeTab = Element(id: 5, role: .tab, label: "World Clock", frame: Rect(x: 0.1, y: 0.9, width: 0.2, height: 0.05))

        let screen = makeDummyScreen(elements: [toggle, textField, key, slider, safeTab])

        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(1)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(2)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(3)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(4)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(5)), on: screen) == nil)
    }

    @Test func refusesTapsOnMutatingLabels() {
        let saveBtn = Element(id: 1, role: .button, label: "Save", frame: Rect(x: 0.8, y: 0.05, width: 0.15, height: 0.04))
        let doneBtn = Element(id: 2, role: .button, label: "Done", frame: Rect(x: 0.8, y: 0.05, width: 0.15, height: 0.04))
        let editBtn = Element(id: 3, role: .button, label: "Edit", frame: Rect(x: 0.05, y: 0.05, width: 0.15, height: 0.04))
        let deleteBtn = Element(id: 4, role: .button, label: "Delete Alarm", frame: Rect(x: 0.1, y: 0.8, width: 0.8, height: 0.05))
        let addBtn = Element(id: 5, role: .button, label: "+", frame: Rect(x: 0.85, y: 0.05, width: 0.1, height: 0.04))
        let checkBtn = Element(id: 6, role: .button, label: "✓", frame: Rect(x: 0.85, y: 0.05, width: 0.1, height: 0.04))
        let repeatRow = Element(id: 7, role: .cell, label: "Repeat", frame: Rect(x: 0.1, y: 0.4, width: 0.8, height: 0.05))
        let okBtn = Element(id: 8, role: .button, label: "OK", frame: Rect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))
        let yesBtn = Element(id: 9, role: .button, label: "Yes", frame: Rect(x: 0.3, y: 0.1, width: 0.2, height: 0.05))
        let eraseBtn = Element(id: 10, role: .button, label: "Erase All Content", frame: Rect(x: 0.1, y: 0.7, width: 0.8, height: 0.05))
        let incBtn = Element(id: 11, role: .button, label: "Increment", frame: Rect(x: 0.5, y: 0.3, width: 0.2, height: 0.05))
        let decBtn = Element(id: 12, role: .button, label: "Decrement", frame: Rect(x: 0.7, y: 0.3, width: 0.2, height: 0.05))
        let safeAlarmsTab = Element(id: 13, role: .tab, label: "Alarms", frame: Rect(x: 0.3, y: 0.9, width: 0.2, height: 0.05))

        let screen = makeDummyScreen(elements: [
            saveBtn, doneBtn, editBtn, deleteBtn, addBtn, checkBtn,
            repeatRow, okBtn, yesBtn, eraseBtn, incBtn, decBtn, safeAlarmsTab
        ])

        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(1)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(2)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(3)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(4)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(5)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(6)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(7)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(8)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(9)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(10)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(11)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(12)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(13)), on: screen) == nil)
    }

    @Test func refusesTapsOnSelectedNonTabElements() {
        let saturdayCell = Element(id: 1, role: .cell, label: "Saturday", frame: Rect(x: 0.1, y: 0.3, width: 0.8, height: 0.05), traits: [.selected])
        let selectedTab = Element(id: 2, role: .tab, label: "Alarms", frame: Rect(x: 0.1, y: 0.9, width: 0.2, height: 0.05), traits: [.selected])
        let unselectedCell = Element(id: 3, role: .cell, label: "Sunday", frame: Rect(x: 0.1, y: 0.4, width: 0.8, height: 0.05))

        let screen = makeDummyScreen(elements: [saturdayCell, selectedTab, unselectedCell])

        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(1)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(2)), on: screen) == nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(3)), on: screen) == nil)
    }

    @Test func refusesTapsOnUnlabeledButtons() {
        let emptyBtn = Element(id: 1, role: .button, label: "", frame: Rect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let whitespaceBtn = Element(id: 2, role: .button, label: "   ", frame: Rect(x: 0.3, y: 0.1, width: 0.1, height: 0.1))
        let labeledBtn = Element(id: 3, role: .button, label: "Cancel", frame: Rect(x: 0.5, y: 0.1, width: 0.2, height: 0.1))

        let screen = makeDummyScreen(elements: [emptyBtn, whitespaceBtn, labeledBtn])

        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(1)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(2)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(3)), on: screen) == nil)
    }

    @Test func refusesPredictiveAndKeyboardAreaTaps() {
        let key = Element(id: 1, role: .keyboardKey, label: "q", frame: Rect(x: 0.1, y: 0.7, width: 0.08, height: 0.05))
        let predictiveWord = Element(id: 2, role: .button, label: "The", frame: Rect(x: 0.1, y: 0.55, width: 0.25, height: 0.04))
        let safeHeader = Element(id: 3, role: .header, label: "Edit Alarm", frame: Rect(x: 0.3, y: 0.05, width: 0.4, height: 0.04))

        let keyboardScreen = makeDummyScreen(elements: [key, predictiveWord, safeHeader])

        // Predictive word button refused when keyboard is active
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(2)), on: keyboardScreen) != nil)

        // Point tap in keyboard/predictive area refused when keyboard is active
        #expect(ReadOnlyPolicy.refusal(for: .tap(.point(Point(x: 0.2, y: 0.55))), on: keyboardScreen) != nil)

        // Point tap in safe top area allowed
        #expect(ReadOnlyPolicy.refusal(for: .tap(.point(Point(x: 0.5, y: 0.05))), on: keyboardScreen) == nil)

        // Screen without keyboard allows tap on ordinary button at bottom
        let normalScreen = makeDummyScreen(elements: [Element(id: 4, role: .button, label: "Stopwatch", frame: Rect(x: 0.5, y: 0.9, width: 0.2, height: 0.05))])
        #expect(ReadOnlyPolicy.refusal(for: .tap(.element(4)), on: normalScreen) == nil)
    }

    @Test func refusesPointTapsLandingInMutatingFrames() {
        let toggle = Element(id: 1, role: .toggle, label: "WiFi", frame: Rect(x: 0.7, y: 0.2, width: 0.2, height: 0.1))
        let saveBtn = Element(id: 2, role: .button, label: "Save", frame: Rect(x: 0.1, y: 0.05, width: 0.2, height: 0.05))
        let screen = makeDummyScreen(elements: [toggle, saveBtn])

        // Landing inside toggle
        let tapInToggle = ReadOnlyPolicy.refusal(for: .tap(.point(Point(x: 0.75, y: 0.25))), on: screen)
        #expect(tapInToggle != nil)
        #expect(tapInToggle?.contains("WiFi") == true)

        // Landing inside Save button
        let tapInSave = ReadOnlyPolicy.refusal(for: .tap(.point(Point(x: 0.15, y: 0.06))), on: screen)
        #expect(tapInSave != nil)
        #expect(tapInSave?.contains("Save") == true)

        // Landing in empty safe area
        #expect(ReadOnlyPolicy.refusal(for: .tap(.point(Point(x: 0.5, y: 0.5))), on: screen) == nil)
    }

    @Test func refusesScrollIntoSlider() {
        let slider = Element(id: 1, role: .slider, label: "Volume", frame: Rect(x: 0.1, y: 0.4, width: 0.8, height: 0.1))
        let screen = makeDummyScreen(elements: [slider])

        #expect(ReadOnlyPolicy.refusal(for: .scroll(.down, in: .element(1)), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .scroll(.down, in: .point(Point(x: 0.5, y: 0.45))), on: screen) != nil)
        #expect(ReadOnlyPolicy.refusal(for: .scroll(.down, in: nil), on: screen) == nil)
    }

    @Test func preparationGesturesSanitization() {
        #expect(ReadOnlyPolicy.isMutating(gesture: .longPress(Point(x: 0.5, y: 0.5))))
        #expect(ReadOnlyPolicy.isMutating(gesture: .type("abc")))
        #expect(ReadOnlyPolicy.isMutating(gesture: .selectAll))
        #expect(ReadOnlyPolicy.isMutating(gesture: .key(.return)))
        #expect(ReadOnlyPolicy.isMutating(gesture: .press(.lock)))
        #expect(!ReadOnlyPolicy.isMutating(gesture: .press(.home)))
        #expect(!ReadOnlyPolicy.isMutating(gesture: .tap(Point(x: 0.5, y: 0.5))))
        #expect(!ReadOnlyPolicy.isMutating(gesture: .launch(bundleID: "com.apple.mobilecal")))
    }

    @Test func briefIncludesReadOnlyNotice() {
        let screen = makeDummyScreen()
        let readOnlyStep = Step(goal: "Open Clock", screen: screen, isReadOnly: true)
        #expect(readOnlyStep.brief().contains("Mode: Read-only"))

        let normalStep = Step(goal: "Open Clock", screen: screen, isReadOnly: false)
        #expect(!normalStep.brief().contains("Mode: Read-only"))
    }

    @Test func agentEnforcesReadOnlyAtRuntime() async throws {
        let toggle = Element(id: 1, role: .toggle, label: "Alarm", frame: Rect(x: 0.7, y: 0.2, width: 0.2, height: 0.1))
        let device = ReadOnlyTestDevice(elements: [toggle])

        // Pilot attempts to tap the toggle, then gives up
        let pilot = TestPilot(.tap(.element(1)), .giveUp(reason: "refused"))
        let agent = Agent(device: device, pilot: pilot, policy: .readOnly, settle: .zero)

        let outcome = try await agent.run("Open Clock and do not change anything")
        #expect(outcome == .abandoned(reason: "refused"))

        // Verify the device NEVER received a tap gesture
        let performed = await device.performedGestures
        #expect(performed.isEmpty)
    }

    @Test func agentAbandonsAfterFiveConsecutiveRefusals() async throws {
        let saveBtn = Element(id: 1, role: .button, label: "Save", frame: Rect(x: 0.7, y: 0.2, width: 0.2, height: 0.1))
        let device = ReadOnlyTestDevice(elements: [saveBtn])

        // Pilot persists in tapping Save 6 times
        let pilot = TestPilot(
            .tap(.element(1)),
            .tap(.element(1)),
            .tap(.element(1)),
            .tap(.element(1)),
            .tap(.element(1)),
            .tap(.element(1))
        )
        let agent = Agent(device: device, pilot: pilot, policy: .readOnly, settle: .zero)

        let outcome = try await agent.run("Open Clock and do not modify anything")
        #expect(outcome == .abandoned(reason: "read-only: kept choosing changes"))

        // Verify the device NEVER received a tap gesture
        let performed = await device.performedGestures
        #expect(performed.isEmpty)
    }
}

private actor TestPilot: Pilot {
    var script: [Action]
    init(_ script: Action...) {
        self.script = script
    }
    func decide(_ step: Step) async throws -> Decision {
        guard !script.isEmpty else {
            return Decision(thought: "done", action: .done(summary: "no more script"))
        }
        return Decision(thought: "acting", action: script.removeFirst())
    }
}

private actor ReadOnlyTestDevice: Device {
    let elements: [Element]
    var performedGestures: [Gesture] = []

    init(elements: [Element]) {
        self.elements = elements
    }

    func observe() throws(DeviceError) -> Screen {
        Screen(screenshot: .blank(width: 100, height: 100), elements: elements)
    }

    func perform(_ gesture: Gesture) throws(DeviceError) {
        performedGestures.append(gesture)
    }

    func installedApps() throws(DeviceError) -> [InstalledApp] { [] }
    func frontmostApp() throws(DeviceError) -> FrontmostApp? { nil }
}

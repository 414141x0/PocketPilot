public import AgentCore
public import FoundationModels

/// The one structured decision schema shared by every FoundationModels-compatible pilot.
@Generable(description: "Agent decision")
public struct Reply: Sendable {
    @Guide(description: "one short sentence") public var thought: String
    public var action: Choice

    public init(thought: String, action: Choice) {
        self.thought = thought
        self.action = action
    }
}

@Generable public enum Heading: Sendable {
    case up, down, left, right

    func toDirection() -> Direction {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

@Generable public enum Key: Sendable {
    case home, lock, volumeUp, volumeDown

    func toButton() -> HardwareButton {
        switch self {
        case .home: .home
        case .lock: .lock
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        }
    }
}

@Generable public enum KeyName: Sendable {
    case `return`, tab, escape, delete

    var key: KeyboardKey {
        switch self {
        case .return: .return
        case .tab: .tab
        case .escape: .escape
        case .delete: .delete
        }
    }
}

@Generable public enum Choice: Sendable {
    case tap(element: Int)
    case tapPoint(x: Int, y: Int)
    case longPress(element: Int)
    case scroll(direction: Heading, element: Int?)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int)
    case type(text: String, replacing: Bool)
    case press(button: Key)
    case key(name: KeyName)
    case open(app: String)
    case wait(seconds: Double)
    case done(summary: String)
    case giveUp(reason: String)
}

/// Converts every schema case to the provider-independent action contract.
public enum PilotDecisionSchema {
    public static func map(_ reply: Reply) -> Decision {
        let action: Action = switch reply.action {
        case .tap(let id): .tap(.element(id))
        case .tapPoint(let x, let y): .tap(.point(Point(grid: x, y)))
        case .longPress(let id): .longPress(.element(id))
        case .scroll(let direction, let id):
            .scroll(direction.toDirection(), in: id.map { .element($0) })
        case .drag(let fromX, let fromY, let toX, let toY):
            .drag(from: .point(Point(grid: fromX, fromY)), to: .point(Point(grid: toX, toY)))
        case .type(let text, let replacing): .type(text, replacing: replacing)
        case .press(let button): .press(button.toButton())
        case .key(let name): .key(name.key)
        case .open(let app): .open(app: app)
        case .wait(let seconds): .wait(seconds: seconds)
        case .done(let summary): .done(summary: summary)
        case .giveUp(let reason): .giveUp(reason: reason)
        }
        return Decision(thought: reply.thought, action: action)
    }
}

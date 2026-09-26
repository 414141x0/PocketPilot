import AgentCore
import Foundation
import FoundationModels
import PilotSchema

/// A compact, bounded wire schema for small MLX models.
///
/// `Choice.generationSchema` remains the shared semantic contract. Its enum payloads contain
/// unbounded integers, though, and xgrammar does not honor Foundation Models' `x-order` hint.
/// A small model can therefore start with an action payload and emit digits until the token cap
/// before it ever reaches the required thought. This flat action envelope bounds every numeric
/// field, then converts back to the shared `Reply` before mapping to `Action`.
enum MLXDecisionSchema {
    static let generationSchema: GenerationSchema = {
        let actionType = DynamicGenerationSchema(
            name: "ActionType",
            anyOf: [
                "tap", "tapPoint", "longPress", "scroll", "drag", "type",
                "press", "key", "open", "wait", "done", "giveUp",
            ]
        )
        let heading = DynamicGenerationSchema(
            name: "Heading",
            anyOf: ["up", "down", "left", "right"]
        )
        let button = DynamicGenerationSchema(
            name: "Button",
            anyOf: ["home", "lock", "volumeUp", "volumeDown"]
        )
        let key = DynamicGenerationSchema(
            name: "KeyName",
            anyOf: ["return", "tab", "escape", "delete"]
        )
        let element = DynamicGenerationSchema(type: Int.self, guides: [.range(1 ... 300)])
        let coordinate = DynamicGenerationSchema(type: Int.self, guides: [.range(0 ... 1_000)])
        let seconds = DynamicGenerationSchema(type: Double.self, guides: [.range(0.25 ... 10)])
        let string = DynamicGenerationSchema(type: String.self)

        let action = DynamicGenerationSchema(
            name: "MLXAction",
            description: "Exactly one iPhone action. Include only the fields that action needs.",
            properties: [
                .init(name: "type", schema: actionType),
                .init(name: "element", description: "A visible element id.", schema: element, isOptional: true),
                .init(name: "x", description: "Grid x coordinate.", schema: coordinate, isOptional: true),
                .init(name: "y", description: "Grid y coordinate.", schema: coordinate, isOptional: true),
                .init(name: "fromX", schema: coordinate, isOptional: true),
                .init(name: "fromY", schema: coordinate, isOptional: true),
                .init(name: "toX", schema: coordinate, isOptional: true),
                .init(name: "toY", schema: coordinate, isOptional: true),
                .init(name: "direction", schema: heading, isOptional: true),
                .init(name: "text", schema: string, isOptional: true),
                .init(name: "replacing", description: "When true, clears existing text before typing.", schema: DynamicGenerationSchema(type: Bool.self), isOptional: true),
                .init(name: "button", schema: button, isOptional: true),
                .init(name: "name", schema: key, isOptional: true),
                .init(name: "app", schema: string, isOptional: true),
                .init(name: "seconds", schema: seconds, isOptional: true),
                .init(name: "summary", schema: string, isOptional: true),
                .init(name: "reason", schema: string, isOptional: true),
            ]
        )
        let root = DynamicGenerationSchema(
            name: "MLXDecision",
            description: "One validated agent decision.",
            properties: [
                .init(
                    name: "thought",
                    description: "A brief rationale with words, not only a number.",
                    schema: string
                ),
                .init(name: "action", schema: action),
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    static func reply(from content: GeneratedContent, on screen: Screen) throws -> Reply {
        let rawThought: String = try content.value(forProperty: "thought")
        let thought = rawThought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard thought.count >= 3,
              thought.rangeOfCharacter(from: .letters) != nil
        else {
            throw MLXDecisionSchemaError.invalid("thought must contain a few words")
        }

        let action: GeneratedContent = try content.value(forProperty: "action")
        let type: String = try action.value(forProperty: "type")
        let choice: Choice
        switch type {
        case "tap":
            let id = try elementID(in: action, on: screen)
            choice = .tap(element: id)
        case "tapPoint":
            choice = .tapPoint(
                x: try coordinate("x", in: action),
                y: try coordinate("y", in: action)
            )
        case "longPress":
            let id = try elementID(in: action, on: screen)
            choice = .longPress(element: id)
        case "scroll":
            let raw: String = try action.value(forProperty: "direction")
            let direction: Heading = switch raw {
            case "up": .up
            case "down": .down
            case "left": .left
            case "right": .right
            default: throw MLXDecisionSchemaError.invalid("unknown scroll direction \(raw)")
            }
            let id: Int? = hasProperty("element", in: action)
                ? try elementID(in: action, on: screen)
                : nil
            choice = .scroll(direction: direction, element: id)
        case "drag":
            choice = .drag(
                fromX: try coordinate("fromX", in: action),
                fromY: try coordinate("fromY", in: action),
                toX: try coordinate("toX", in: action),
                toY: try coordinate("toY", in: action)
            )
        case "type":
            let replacing: Bool = hasProperty("replacing", in: action)
                ? (try action.value(forProperty: "replacing"))
                : false
            choice = .type(text: try nonemptyString("text", in: action), replacing: replacing)
        case "press":
            let raw: String = try action.value(forProperty: "button")
            let button: Key = switch raw {
            case "home": .home
            case "lock": .lock
            case "volumeUp": .volumeUp
            case "volumeDown": .volumeDown
            default: throw MLXDecisionSchemaError.invalid("unknown button \(raw)")
            }
            choice = .press(button: button)
        case "key":
            let raw: String = try action.value(forProperty: "name")
            let name: KeyName = switch raw {
            case "return": .return
            case "tab": .tab
            case "escape": .escape
            case "delete": .delete
            default: throw MLXDecisionSchemaError.invalid("unknown key \(raw)")
            }
            choice = .key(name: name)
        case "open":
            choice = .open(app: try nonemptyString("app", in: action))
        case "wait":
            let value: Double = try action.value(forProperty: "seconds")
            guard value.isFinite, 0.25 ... 10 ~= value else {
                throw MLXDecisionSchemaError.invalid("wait seconds must be between 0.25 and 10")
            }
            choice = .wait(seconds: value)
        case "done":
            choice = .done(summary: try nonemptyString("summary", in: action))
        case "giveUp":
            choice = .giveUp(reason: try nonemptyString("reason", in: action))
        default:
            throw MLXDecisionSchemaError.invalid("unknown action type \(type)")
        }
        return Reply(thought: String(thought.prefix(240)), action: choice)
    }

    private static func elementID(in action: GeneratedContent, on screen: Screen) throws -> Int {
        let id: Int = try action.value(forProperty: "element")
        guard 1 ... 300 ~= id, screen[id] != nil else {
            throw MLXDecisionSchemaError.invalid("element \(id) is not present on this screen")
        }
        return id
    }

    private static func coordinate(_ name: String, in action: GeneratedContent) throws -> Int {
        let value: Int = try action.value(forProperty: name)
        guard 0 ... 1_000 ~= value else {
            throw MLXDecisionSchemaError.invalid("\(name) must be between 0 and 1000")
        }
        return value
    }

    private static func nonemptyString(_ name: String, in action: GeneratedContent) throws -> String {
        let raw: String = try action.value(forProperty: name)
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw MLXDecisionSchemaError.invalid("\(name) must not be empty")
        }
        return value
    }

    private static func hasProperty(_ name: String, in content: GeneratedContent) -> Bool {
        guard case .structure(let properties, _) = content.kind else { return false }
        return properties[name] != nil
    }
}

enum MLXDecisionSchemaError: LocalizedError, Sendable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Invalid local-model decision: \(reason)."
        }
    }
}

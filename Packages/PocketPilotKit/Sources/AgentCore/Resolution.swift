extension Action {
    /// The concrete gesture for this action on `screen`, or `nil`
    /// when the action needs no input (waiting, finishing). `apps` resolves app names.
    public func gesture(on screen: Screen, apps: [InstalledApp] = []) throws(ResolutionError) -> Gesture? {
        switch self {
        case .tap(let target): .tap(try screen.point(for: target))
        case .longPress(let target): .longPress(try screen.point(for: target))
        case .scroll(let direction, let target): .swipe(direction, in: try screen.frame(for: target))
        case .drag(let from, let to): .swipe(from: try screen.point(for: from), to: try screen.point(for: to))
        case .type(let text, _): .type(text)
        case .press(let button): .press(button)
        case .key(let key): .key(key)
        case .open(let app): .launch(bundleID: try apps.bundleID(for: app))
        case .wait, .done, .giveUp: nil
        }
    }
}

public enum ResolutionError: Error, Sendable, Hashable, CustomStringConvertible {
    case unknownElement(Element.ID)
    case unknownApp(String, similar: [String])

    public var description: String {
        switch self {
        case .unknownElement(let id): "No element with id \(id) is on screen."
        case .unknownApp(let name, []): "No installed app is named \"\(name)\"."
        case .unknownApp(let name, let similar):
            "No installed app is named \"\(name)\". Similar: \(similar.joined(separator: ", "))."
        }
    }
}

extension Screen {
    func point(for target: Target) throws(ResolutionError) -> Point {
        switch target {
        case .point(let point): point
        case .element(let id): try element(id).frame.center
        }
    }

    func frame(for target: Target?) throws(ResolutionError) -> Rect {
        switch target {
        case nil: .fullScreen
        case .point(let point): Rect(x: point.x - 0.25, y: point.y - 0.25, width: 0.5, height: 0.5)
        case .element(let id): try element(id).frame
        }
    }

    private func element(_ id: Element.ID) throws(ResolutionError) -> Element {
        guard let element = self[id] else { throw .unknownElement(id) }
        return element
    }
}

extension Rect {
    public static let fullScreen = Rect(x: 0, y: 0, width: 1, height: 1)
}

extension Gesture {
    /// A swipe that scrolls `region`'s content toward `direction`; the finger travels the opposite way.
    static func swipe(_ direction: Direction, in region: Rect) -> Gesture {
        let center = region.center
        let dx = region.width * 0.3, dy = region.height * 0.3
        let (start, end): (Point, Point) = switch direction {
        case .down: (Point(x: center.x, y: center.y + dy), Point(x: center.x, y: center.y - dy))
        case .up: (Point(x: center.x, y: center.y - dy), Point(x: center.x, y: center.y + dy))
        case .right: (Point(x: center.x + dx, y: center.y), Point(x: center.x - dx, y: center.y))
        case .left: (Point(x: center.x - dx, y: center.y), Point(x: center.x + dx, y: center.y))
        }
        return .swipe(from: start, to: end)
    }
}

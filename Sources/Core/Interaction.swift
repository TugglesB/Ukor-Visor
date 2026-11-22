import Foundation

enum VisorVisibility {
    case collapsed, opening, expanded, closing

    var showsSurface: Bool { self != .collapsed }
    var acceptsControlClicks: Bool { self == .expanded }
    var isOpen: Bool { self == .opening || self == .expanded }
}

enum DirectionGlyph {
    static func tipVector(for key: RokuKey, flipped: Bool) -> CGVector? {
        let up: CGFloat = flipped ? -1 : 1
        switch key {
        case .up: return CGVector(dx: 0, dy: up)
        case .down: return CGVector(dx: 0, dy: -up)
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        default: return nil
        }
    }
}

struct MotionPreference {
    let animationsEnabled: Bool
    let reduceMotion: Bool
    var duration: TimeInterval { animationsEnabled && !reduceMotion ? 0.31 : 0 }
}

@MainActor
final class DirectionRepeat {
    private let initial: Duration
    private let cadence: Duration
    private var task: Task<Void, Never>?

    init(initial: Duration = .milliseconds(330), cadence: Duration = .milliseconds(120)) {
        self.initial = initial
        self.cadence = cadence
    }

    func start(_ key: RokuKey, send: @escaping (RokuKey, Bool) -> Void) {
        stop()
        guard key.repeats else { return }
        send(key, false)
        task = Task { [initial, cadence] in
            do {
                try await Task.sleep(for: initial)
                while !Task.isCancelled {
                    send(key, true)
                    try await Task.sleep(for: cadence)
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

import AppKit

/// Rewrites mouse button events in place via a CGEventTap.
final class Remapper {
    private let mappings: [Int64: Int64]
    private let blocked: Set<Int64>
    private let verbose: Bool
    private var tap: CFMachPort?
    /// Click tracking per target button, so double/triple-click works on remapped buttons.
    private var lastDown: [Int64: (time: TimeInterval, loc: CGPoint, count: Int64)] = [:]

    init(config: Config, verbose: Bool) {
        mappings = Dictionary(uniqueKeysWithValues: config.mappings.map { ($0.from.cgButton, $0.to.cgButton) })
        blocked = Set(config.blocked.map(\.cgButton))
        self.verbose = verbose
    }

    /// Installs the tap on the current run loop. Returns false if the tap couldn't be created.
    func start() -> Bool {
        var mask: CGEventMask = 0
        for t in [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                  .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                  .otherMouseDown, .otherMouseUp, .otherMouseDragged] {
            mask |= CGEventMask(1) << CGEventMask(t.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let remapper = Unmanaged<Remapper>.fromOpaque(userInfo!).takeUnretainedValue()
            return remapper.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private enum Phase: String { case down, up, dragged }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let phase: Phase, button: Int64
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables slow/idle taps; turn it back on.
            log("tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown: (phase, button) = (.down, 0)
        case .leftMouseUp: (phase, button) = (.up, 0)
        case .leftMouseDragged: (phase, button) = (.dragged, 0)
        case .rightMouseDown: (phase, button) = (.down, 1)
        case .rightMouseUp: (phase, button) = (.up, 1)
        case .rightMouseDragged: (phase, button) = (.dragged, 1)
        case .otherMouseDown: (phase, button) = (.down, event.getIntegerValueField(.mouseEventButtonNumber))
        case .otherMouseUp: (phase, button) = (.up, event.getIntegerValueField(.mouseEventButtonNumber))
        case .otherMouseDragged: (phase, button) = (.dragged, event.getIntegerValueField(.mouseEventButtonNumber))
        default: return Unmanaged.passUnretained(event)
        }

        // Rewritten events don't pass back through this tap, so these are always physical events
        // and swapping two buttons works.
        if blocked.contains(button) {
            if phase != .dragged { log("blocked button \(button + 1) \(phase)") }
            return nil
        }
        guard let target = mappings[button] else { return Unmanaged.passUnretained(event) }

        if phase == .down {
            // Track click count ourselves: the original event's click state belongs to the source button.
            let now = ProcessInfo.processInfo.systemUptime
            let loc = event.location
            var count: Int64 = 1
            if let last = lastDown[target],
               now - last.time <= NSEvent.doubleClickInterval,
               hypot(loc.x - last.loc.x, loc.y - last.loc.y) < 5 {
                count = last.count + 1
            }
            lastDown[target] = (now, loc, count)
        }
        let clickCount = lastDown[target]?.count ?? 1

        event.type = Self.eventType(phase: phase, button: target)
        event.setIntegerValueField(.mouseEventButtonNumber, value: target)
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)

        // Drags are too frequent to be worth logging.
        if phase != .dragged {
            log("button \(button + 1) \(phase) → button \(target + 1) \(phase) (clicks=\(clickCount)) at \(Int(event.location.x)),\(Int(event.location.y))")
        }
        return Unmanaged.passUnretained(event)
    }

    private static func eventType(phase: Phase, button: Int64) -> CGEventType {
        switch (button, phase) {
        case (0, .down): .leftMouseDown
        case (0, .up): .leftMouseUp
        case (0, .dragged): .leftMouseDragged
        case (1, .down): .rightMouseDown
        case (1, .up): .rightMouseUp
        case (1, .dragged): .rightMouseDragged
        case (_, .down): .otherMouseDown
        case (_, .up): .otherMouseUp
        case (_, .dragged): .otherMouseDragged
        }
    }

    private func log(_ message: String) {
        guard verbose else { return }
        print("\(Date().formatted(.iso8601)) \(message)")
    }
}

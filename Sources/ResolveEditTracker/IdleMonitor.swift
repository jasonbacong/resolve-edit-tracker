import Foundation
import CoreGraphics

/// System-wide input idle time. Uses Quartz Event Services, which needs no
/// Accessibility or Input-Monitoring permission for *reading* idle time.
enum IdleMonitor {
    static func idleSeconds() -> Double {
        // kCGAnyInputEventType == ~0
        if let anyInput = CGEventType(rawValue: ~UInt32(0)) {
            let v = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            if v.isFinite && v >= 0 { return v }
        }
        // Fallback: minimum across the common input event types.
        let types: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
            .min() ?? 0
    }
}

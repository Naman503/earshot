import CoreGraphics
import Foundation

/// A multi-finger tap on the trackpad: `fingers` touching together and lifted
/// quickly without moving, `taps` times in a row.
public struct TrackpadTap: Hashable, Codable, Sendable, Comparable {
    public var fingers: Int
    public var taps: Int
    public init(fingers: Int, taps: Int) { self.fingers = fingers; self.taps = taps }

    public static func < (a: Self, b: Self) -> Bool { (a.fingers, a.taps) < (b.fingers, b.taps) }

    public var label: String {
        let count = taps == 1 ? "Tap" : taps == 2 ? "Double-tap" : "Triple-tap"
        return "\(count) with \(fingers) fingers"
    }

    public static let all: [TrackpadTap] = (3...5).flatMap { f in (1...3).map { TrackpadTap(fingers: f, taps: $0) } }
}

/// Recognizes multi-finger taps from raw trackpad frames. Pure state machine:
/// feed frames, call `tick` periodically, collect the gestures returned.
public struct TapRecognizer {
    public struct Frame: Sendable {
        public var time: Double
        /// Normalized (0...1) positions of fingers currently touching.
        public var points: [CGPoint]
        public init(time: Double, points: [CGPoint]) { self.time = time; self.points = points }
    }

    public var minFingers = 3
    public var maxTapDuration = 0.35
    public var maxMovement = 0.04
    public var multiTapWindow = 0.30
    /// Highest bound tap count per finger count. A tap that could still become
    /// a longer bound sequence waits `multiTapWindow` for the next tap.
    public var maxTaps: [Int: Int] = [:]

    private var touchStart: Double?
    private var maxFingers = 0
    private var anchor: CGPoint?
    private var anchorFingers = 0
    private var moved = 0.0
    private var pending: (fingers: Int, taps: Int, at: Double)?

    public init() {}

    public mutating func feed(_ frame: Frame) -> [TrackpadTap] {
        var out = flush(now: frame.time, force: false)
        let n = frame.points.count
        if n > 0 {
            if touchStart == nil {
                touchStart = frame.time
                maxFingers = 0
                anchor = nil
                moved = 0
            }
            let c = Self.centroid(frame.points)
            if n > maxFingers {
                maxFingers = n
                anchor = c
                anchorFingers = n
            } else if n == anchorFingers, let a = anchor {
                moved = max(moved, hypot(c.x - a.x, c.y - a.y))
            }
            return out
        }
        // All fingers lifted.
        guard let start = touchStart else { return out }
        touchStart = nil
        let isTap = maxFingers >= minFingers && frame.time - start <= maxTapDuration && moved <= maxMovement
        guard isTap else { pending = nil; return out }

        if let p = pending, p.fingers == maxFingers {
            pending = (p.fingers, p.taps + 1, frame.time)
        } else {
            if let p = pending { out.append(TrackpadTap(fingers: p.fingers, taps: p.taps)) }
            pending = (maxFingers, 1, frame.time)
        }
        if let p = pending, p.taps >= (maxTaps[p.fingers] ?? 1) {
            out.append(TrackpadTap(fingers: p.fingers, taps: p.taps))
            pending = nil
        }
        return out
    }

    /// Emits a waiting single tap once the multi-tap window has passed.
    public mutating func tick(now: Double) -> [TrackpadTap] { flush(now: now, force: false) }

    private mutating func flush(now: Double, force: Bool) -> [TrackpadTap] {
        guard let p = pending, touchStart == nil, force || now - p.at > multiTapWindow else { return [] }
        pending = nil
        return [TrackpadTap(fingers: p.fingers, taps: p.taps)]
    }

    static func centroid(_ pts: [CGPoint]) -> CGPoint {
        let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
    }
}

import AppKit
import EarshotCore
import Foundation

/// Raw trackpad touches from the private MultitouchSupport framework (the same
/// source BetterTouchTool and Jitouch use), fed into `TapRecognizer`.
/// Loaded with dlopen so a missing symbol disables gestures instead of crashing.
@MainActor
final class Trackpad {
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// Size of MTTouch and offsets used from it (stable since 10.x).
    nonisolated private static let touchStride = 96
    nonisolated private static let stateOffset = 20
    nonisolated private static let positionOffset = 32

    var onGesture: ((TrackpadTap) -> Void)?
    private(set) var available = false
    private var devices: [UnsafeMutableRawPointer] = []
    private var stopFn: Stop?
    private var unregisterFn: Register?
    nonisolated(unsafe) private static weak var current: Trackpad?
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var recognizer = TapRecognizer()
    private var ticker: Timer?

    func start(multiTapFingers: Set<Int>) {
        Self.lock.withLock { Self.recognizer.multiTapFingers = multiTapFingers }
        guard devices.isEmpty else { return }
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let create = dlsym(lib, "MTDeviceCreateList"),
              let register = dlsym(lib, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(lib, "MTUnregisterContactFrameCallback"),
              let start = dlsym(lib, "MTDeviceStart"),
              let stop = dlsym(lib, "MTDeviceStop") else {
            Log.write("trackpad: MultitouchSupport unavailable")
            return
        }
        let createList = unsafeBitCast(create, to: CreateList.self)
        let registerFn = unsafeBitCast(register, to: Register.self)
        let startFn = unsafeBitCast(start, to: Start.self)
        unregisterFn = unsafeBitCast(unregister, to: Register.self)
        stopFn = unsafeBitCast(stop, to: Stop.self)

        guard let list = createList()?.takeUnretainedValue() as? [AnyObject] else { return }
        Self.current = self
        for dev in list {
            let ptr = Unmanaged.passUnretained(dev).toOpaque()
            registerFn(ptr, Self.callback)
            startFn(ptr, 0)
            devices.append(ptr)
        }
        available = !devices.isEmpty
        Log.write("trackpad: listening on \(devices.count) device(s)")
        // Flush single taps that were waiting for a possible double tap.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let out = Self.lock.withLock { Self.recognizer.tick(now: now) }
            MainActor.assumeIsolated { out.forEach { Self.current?.onGesture?($0) } }
        }
    }

    func stop() {
        for d in devices {
            unregisterFn?(d, Self.callback)
            stopFn?(d)
        }
        devices.removeAll()
        ticker?.invalidate()
        ticker = nil
        available = false
    }

    /// Re-attach after sleep or when a Magic Trackpad connects.
    func restart(multiTapFingers: Set<Int>) {
        stop()
        start(multiTapFingers: multiTapFingers)
    }

    nonisolated private static let callback: Callback = { _, touches, count, timestamp, _ in
        var points: [CGPoint] = []
        if let touches, count > 0 {
            for i in 0..<Int(count) {
                let t = touches + i * touchStride
                let state = t.load(fromByteOffset: stateOffset, as: Int32.self)
                // 3 = make touch, 4 = touching; skip hovering and lifting fingers.
                guard state == 3 || state == 4 else { continue }
                let x = t.load(fromByteOffset: positionOffset, as: Float.self)
                let y = t.load(fromByteOffset: positionOffset + 4, as: Float.self)
                points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }
        let frame = TapRecognizer.Frame(time: ProcessInfo.processInfo.systemUptime, points: points)
        let out = lock.withLock { recognizer.feed(frame) }
        if !out.isEmpty {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { out.forEach { current?.onGesture?($0) } }
            }
        }
        return 0
    }
}

import AppKit
import CoreVideo
import QuartzCore

/// Drives the render loop and hands back a clamped delta time each tick. Used by both
/// the harness view and the screensaver view.
///
/// - macOS 14+: a view-bound CADisplayLink (follows the view's display, supports a
///   preferred frame-rate range).
/// - macOS 12–13: a CVDisplayLink bound to the view's current display, with ticks
///   marshalled to the main thread and the frame-rate cap applied by skipping ticks.
final class DisplayLinkDriver: NSObject {
    private var link: AnyObject?           // CADisplayLink on macOS 14+
    private var cvLink: CVDisplayLink?     // fallback on macOS 12–13
    private weak var view: NSView?
    private let onTick: (Double) -> Void
    private var last: CFTimeInterval = 0
    private var minInterval: CFTimeInterval = 0
    private var tickPending = false        // main-thread only; coalesces CV callbacks
    private let lock = NSLock()

    init(view: NSView, onTick: @escaping (Double) -> Void) {
        self.view = view
        self.onTick = onTick
        super.init()
    }

    deinit { stop() }

    func start(preferredFPS: Int) {
        stop()
        guard let view else { return }
        last = 0
        // MM_FORCE_CVDISPLAYLINK=1 exercises the Monterey/Ventura path on newer macOS.
        let forceCV = ProcessInfo.processInfo.environment["MM_FORCE_CVDISPLAYLINK"] == "1"
        if #available(macOS 14.0, *), !forceCV {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            if preferredFPS > 0 {
                let hi = Float(preferredFPS)
                l.preferredFrameRateRange = CAFrameRateRange(
                    minimum: min(hi, 30), maximum: hi, preferred: hi)
            }
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            startCVDisplayLink(view: view, preferredFPS: preferredFPS)
        }
    }

    func stop() {
        if #available(macOS 14.0, *) {
            (link as? CADisplayLink)?.invalidate()
        }
        link = nil
        if let cv = cvLink {
            CVDisplayLinkStop(cv)
            cvLink = nil
        }
    }

    @available(macOS 14.0, *)
    @objc private func tick(_ l: CADisplayLink) {
        deliver(now: l.timestamp)
    }

    private func deliver(now: CFTimeInterval) {
        let dt = last == 0 ? 1.0 / 60.0 : max(0, min(0.1, now - last))
        last = now
        onTick(dt)
    }

    // MARK: - CVDisplayLink fallback (macOS 12–13)

    private func startCVDisplayLink(view: NSView, preferredFPS: Int) {
        // Small tolerance so a 60 FPS cap on a 60 Hz display doesn't drop every other frame.
        minInterval = preferredFPS > 0 ? (1.0 / Double(preferredFPS)) * 0.9 : 0

        var cv: CVDisplayLink?
        let displayID = (view.window?.screen ?? NSScreen.main)
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
            .map { CGDirectDisplayID($0.uint32Value) }
        if let displayID {
            CVDisplayLinkCreateWithCGDisplay(displayID, &cv)
        }
        if cv == nil { CVDisplayLinkCreateWithActiveCGDisplays(&cv) }
        guard let cv else { return }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(cv, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let me = Unmanaged<DisplayLinkDriver>.fromOpaque(userInfo).takeUnretainedValue()
            me.cvFired()
            return kCVReturnSuccess
        }, ctx)
        cvLink = cv
        CVDisplayLinkStart(cv)
    }

    /// Called on the CVDisplayLink thread.
    private func cvFired() {
        lock.lock()
        if tickPending { lock.unlock(); return }   // main thread still busy; drop this vsync
        tickPending = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.tickPending = false; self.lock.unlock()
            guard self.cvLink != nil else { return }
            let now = CACurrentMediaTime()
            if self.minInterval > 0, self.last != 0, now - self.last < self.minInterval { return }
            self.deliver(now: now)
        }
    }
}

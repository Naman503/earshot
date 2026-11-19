import AppKit
import EarshotCore
import ScreenCaptureKit
import SwiftUI

/// A small floating "now reading" bar at the bottom of the screen, plus a
/// brief outline around the text that was picked up.
@MainActor
final class HUD {
    private let panel: NSPanel
    private let reader: Reader
    private let settings: Settings
    private var highlight: NSWindow?
    private let marker = WordMarker()
    private let finder = DispatchQueue(label: "earshot.words", qos: .userInteractive)
    private var busy = false
    private var pending: (String, String, WordLocator)?
    private var missedSince: Date?

    private var scrollMonitor: Any?

    /// Earshot's overlays (bar, word marker, outline) show over whatever app
    /// you're in: on every desktop, over full-screen apps, and with Stage
    /// Manager, which otherwise hides them because they aren't the front app's.
    nonisolated(unsafe) static var overlayBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications, .auxiliary]

    init(reader: Reader, settings: Settings) {
        self.reader = reader
        self.settings = settings
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = HUD.overlayBehavior
        panel.contentView = NSHostingView(rootView: HUDView(reader: reader, settings: settings))
        // While you scroll or drag a window, the marker stays on the word that
        // was being read and moves with the page, so you can scroll back to it;
        // reading carries on, and the marker catches up when you stop.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.pageMoved(e) }
        }
        // A click on a word while reading jumps the voice there.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            MainActor.assumeIsolated { self?.clicked(e) }
        }
        // Paging with the keyboard (Page Up/Down, arrows, Space, Home/End) is you
        // moving the page too: auto-scroll waits.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard [116, 121, 125, 126, 115, 119, 49].contains(Int(e.keyCode)) else { return }
            MainActor.assumeIsolated { self?.lastUserScroll = Date() }
        }
        // Switching apps or desktops: hide the marker unless the app being read
        // is the one in front; coming back, the next word shows it again.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.activeSpaceDidChangeNotification {
                        self.marker.newDesktop()  // a fresh marker window on the desktop you moved to
                    }
                    self.marker.hide()
                    if self.sourceInFront { self.findNext() }
                }
            }
        }
    }

    /// Shows the bar while reading or while a notice is up.
    func update() {
        let visible = settings.showHUD && reader.isActive || reader.notice != nil
        if visible {
            if !panel.isVisible { place() }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 24))
    }

    // MARK: Follow-along word highlight

    /// Moves the marker to `word` on the page. Lookups run one at a time off
    /// the main thread; if the page is slow, words in between are skipped.
    func showWord(_ word: String?, next: String, locator: WordLocator?) {
        guard let word, let locator, settings.highlightWords else {
            if word == nil || locator == nil { hideWord() }
            return
        }
        pending = (word, next, locator)
        if lastLocator !== locator { ocrStale = false }
        lastLocator = locator
        findNext()  // even while you scroll: the highlight follows the voice
    }

    private var lastLocator: WordLocator?
    /// Pending "you stopped scrolling" moment; non-nil while scrolling.
    private var scrollEnd: DispatchWorkItem?
    private var lastFollow = Date.distantPast

    private let scroller = SmoothScroller()

    /// Page-turn style following. You read normally down the window; when
    /// the spoken line comes within about three lines of the bottom, the page
    /// glides up about four lines, slowly and smoothly, and reading goes on.
    /// The highlight rides with the page step by step, so it never lags behind.
    /// If the spoken word is out of sight (you scrolled away), it glides back
    /// so the word sits a third of the way down.
    /// `pageEnd`: nil = not measured; .some(nil) = no text below the window
    /// (the page's end is in view); .some(y) = the lowest text below it ends at y.
    private func follow(_ box: CGRect, in view: CGRect, textEnd pageEnd: CGFloat?? = nil) {
        guard let locator = lastLocator, !scroller.isBusy else { return }
        learnLineGap(box)
        let gap = lineGap ?? max(box.height * 1.6, 18)
        let roomBelow = view.maxY - box.maxY
        let outOfSight = box.minY < view.minY + 2 || box.maxY > view.maxY - 2
        let nearBottom = roomBelow < gap * CGFloat(settings.autoScrollTrigger)
        guard nearBottom || outOfSight, !glidesGaveUp else { return }

        // Scrolls go where the pointer is, so glide only with it resting over
        // the page; otherwise, once the word leaves the window, bring it into
        // view the plain way.
        guard SmoothScroller.canScroll(pid: locator.pid, view: view) else {
            guard outOfSight, settings.autoScrollJumpOffPointer, Date().timeIntervalSince(lastAutoScroll) > 0.8 else { return }
            lastAutoScroll = Date()
            stats.scrolled += 1
            finder.async { _ = locator.scrollToKeepVisible() }
            return
        }
        // The page didn't move last time (its end): only try again once the
        // word is out of sight.
        if pageStuck, !outOfSight {
            // Stuck only means "at the page's end": with page text still below
            // the window (new text arrived, or a stop was misjudged), glide again.
            // Only text that wasn't there when it stopped counts (new text
            // arrived): the same "text below" that didn't move is out of reach.
            guard case .some(.some(let bottom)) = pageEnd, bottom > view.maxY + gap * 2,
                  bottom > (stuckEnd ?? -.greatestFiniteMagnitude) + gap else { return }
        }
        pageStuck = false
        stuckEnd = nil

        let dy: CGFloat
        if outOfSight {
            dy = max(-view.height, min(view.height, box.midY - (view.minY + view.height * settings.autoScrollReturn)))
        } else {
            var want = min(gap * CGFloat(settings.autoScrollLines), view.height * 0.7)
            // Never past the end of the page: the full glide while there's
            // page text below the window, as far as that text goes when it's
            // less, and none once the page's end is already on screen.
            if let measured = pageEnd {
                guard let bottom = measured else { return }
                want = min(want, bottom - view.maxY + gap)
                if want < gap * 0.75 { return }
            }
            dy = want
        }
        let base = settings.autoScrollGlide
        let duration = outOfSight ? min(base + 0.4, base * 0.7 + Double(abs(dy)) / 2500) : base
        lastAutoScroll = Date()
        stats.scrolled += 1
        let startY = box.midY
        glideEnd = pageEnd.flatMap { $0 } ?? view.maxY
        gliding = true
        beginTracking(locator, glide: true, dir: dy > 0 ? 1 : -1)
        scroller.scroll(by: dy, pid: locator.pid, view: view, duration: duration, easing: settings.autoScrollEasing, step: { [weak self] delta, _ in
            self?.trackMoved(delta)  // the highlight moves with the page, in the same step
        }, done: { [weak self] in
            // Apps like Claude report where text is a beat after it moves, so
            // wait for the page to settle before measuring again. Until then
            // the highlight keeps riding with the glide instead of jumping to
            // a stale spot.
            guard let self else { return }
            self.finder.asyncAfter(deadline: .now() + 0.25) {
                let now = locator.remeasure()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.gliding else { return }  // already settled (the page stopped early)
                        self.gliding = false
                        self.tracking = nil
                        defer { self.findNext() }
                        guard let now else { return }
                        let moved = startY - now.midY
                        Log.write("highlight: glide \(Int(dy)) px in \(String(format: "%.2f", duration)) s, text moved \(Int(moved)) px")
                        // Moved much less than asked: the page hit its end.
                        if abs(moved) < abs(dy) * 0.6 { self.pageStuck = true; self.stuckEnd = self.glideEnd }
                        // A big glide that did nothing: the page (or its measuring)
                        // is broken — stop auto-scrolls until you scroll yourself.
                        if abs(moved) < 10, abs(dy) > 150 {
                            self.glidesGaveUp = true
                            Log.write("highlight: that glide did nothing — no more auto-scrolls until you scroll")
                        }
                        if self.sourceInFront, self.lastLocator === locator { self.marker.show(now) }
                    }
                }
            }
        })
    }

    /// True from the start of a glide until the page has settled after it;
    /// words wait meanwhile, so the highlight never jumps to a stale spot.
    private var gliding = false

    /// The distance between lines on this page, learned from the reading.
    private var lineGap: CGFloat?
    private var lastLineY: CGFloat?
    private func learnLineGap(_ box: CGRect) {
        defer { lastLineY = box.midY }
        guard let last = lastLineY else { return }
        let d = box.midY - last
        if d > box.height * 0.8, d < box.height * 3 {  // moved down exactly one line
            lineGap = lineGap.map { $0 * 0.7 + d * 0.3 } ?? d
        }
    }

    /// Set when a glide didn't move the page; cleared by your own scrolling
    /// or a new reading.
    private var pageStuck = false
    /// Where the page's text ended when it got stuck, and when the last glide began.
    private var stuckEnd: CGFloat?
    private var glideEnd: CGFloat?
    /// Set when a large glide provably moved nothing: no more auto-scrolls
    /// this reading until you scroll yourself.
    private var glidesGaveUp = false

    /// When you last scrolled or paged yourself (auto-scroll waits after it).
    private var lastUserScroll = Date.distantPast
    private var lastAutoScroll = Date.distantPast
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    /// A plain click on a word of the page being read: the voice jumps there.
    private func clicked(_ e: NSEvent) {
        guard settings.clickToJump, settings.highlightWords, reader.isActive, sourceInFront,
              e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              e.clickCount == 1, let locator = lastLocator,
              let point = CGEvent(source: nil)?.location else { return }
        // Only clicks on the page being read (OCR words hit-test themselves).
        if let view = lastView, !view.contains(point) { return }
        finder.async {
            guard let snippet = locator.textNear(point: point) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.lastLocator === locator else { return }
                    _ = self.reader.jump(toTextNear: snippet)
                }
            }
        }
    }

    private func pageMoved(_ e: NSEvent) {
        // Earshot's own smooth scrolling isn't you taking over.
        if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == SmoothScroller.tag { return }
        lastUserScroll = Date()
        // OCR boxes come from one screenshot: once the page moves they're wrong,
        // so the highlight bows out for the rest of this reading.
        if lastLocator?.tracksScrolling == false {
            if !ocrStale { Log.write("highlight: page scrolled during an OCR reading — hiding the highlight") }
            ocrStale = true
            marker.hide()
            return
        }
        pageStuck = false
        stuckEnd = nil
        glidesGaveUp = false
        scrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrollEnd = nil
            self.findNext()
        }
        scrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: end)
        // Your own scroll over the page being read: move the highlight by the
        // same amount in the same moment (the app reports new text positions
        // only a beat later), then measure once the page settles.
        if e.type == .scrollWheel, let view = lastView,
           view.contains(CGEvent(source: nil)?.location ?? .zero), sourceInFront {
            // A mouse wheel reports lines, not pixels: ride it all the same.
            followUserScroll(e.hasPreciseScrollingDeltas ? -e.scrollingDeltaY : -e.scrollingDeltaY * 18)
            settleAfterScroll?.cancel()
            let settle = DispatchWorkItem { [weak self] in self?.remeasureMarker() }
            settleAfterScroll = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: settle)
            return
        }
        // Otherwise keep the marker on the last word read as the page moves (~30 times a second).
        guard !busy, Date().timeIntervalSince(lastFollow) > 0.033, let locator = lastLocator else { return }
        lastFollow = Date()
        busy = true
        finder.async {
            let box = locator.remeasure()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    // Only between words: a fresher word may have been placed since.
                    if let box, self.sourceInFront, self.pending == nil { self.marker.show(box) }
                    self.findNext()
                }
            }
        }
    }

    private var lastView: CGRect?

    /// The direction the page couldn't move last time (+1 content up = at the
    /// bottom, -1 = at the top, 0 = free).
    private var scrollEdge = 0

    /// The highlight riding along with a moving page — your swipe or an
    /// Earshot glide. It moves by each scroll step at once (the app reports
    /// text positions only a beat later), while a check ten times a second
    /// confirms the text really is moving. When the page stops (its end, part
    /// way through a swipe or glide), the highlight stops too and settles on
    /// its word instead of drifting off up or down.
    private struct Tracking {
        let locator: WordLocator
        let glide: Bool
        let dir: Int
        var startY: CGFloat
        var sent: CGFloat = 0
        /// How much of each scrolled pixel the page really moves (1 normally,
        /// falling to 0 at the page's end), learned from the checks.
        var ratio: CGFloat = 1
        /// Marker shift applied so far, and page movement the checks confirmed.
        var shown: CGFloat = 0
        var verified: CGFloat = 0
        var frozen: Bool
        var last = Date()
        /// (moved so far as measured, sent so far when measured), newest last.
        var probes: [(moved: CGFloat, sent: CGFloat, at: Date)] = []
    }
    private var tracking: Tracking?
    private var trackTimer: Timer?

    private func beginTracking(_ locator: WordLocator, glide: Bool, dir: Int) {
        guard let y = marker.currentRect?.midY else { tracking = nil; return }
        // Stuck this way last time: hold still until a check shows it moves.
        tracking = Tracking(locator: locator, glide: glide, dir: dir, startY: y, frozen: scrollEdge == dir)
        guard trackTimer == nil else { return }
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeTracking() }
        }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    private func trackMoved(_ dy: CGFloat) {
        guard var t = tracking else { marker.shift(by: dy); return }
        t.sent += dy
        t.last = Date()
        if !t.frozen, t.ratio > 0.02 {
            // Ride along, but never run more than ~a line and a half past what
            // the checks have confirmed the page really did: a flick at the
            // page's end then barely moves the marker instead of flinging it.
            let want = t.shown + dy * t.ratio
            let capped = max(t.verified - 36, min(t.verified + 36, want))
            marker.shift(by: capped - t.shown)
            t.shown = capped
        }
        tracking = t
    }

    private var probing = false
    private func probeTracking() {
        guard let t = tracking else { trackTimer?.invalidate(); trackTimer = nil; return }
        // Your swipe has ended (no steps for a while): the settle check takes over.
        if !t.glide, Date().timeIntervalSince(t.last) > 0.4 {
            // A ride the page mostly ignored marks this end of the page.
            if abs(t.sent) > 30, t.ratio < 0.3 { scrollEdge = t.dir }
            tracking = nil
            return
        }
        guard !probing else { return }
        probing = true
        let locator = t.locator
        let sentNow = t.sent
        finder.async {
            let now = locator.remeasure()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.probing = false
                    guard let now, var t = self.tracking, t.locator === locator else { return }
                    let moved = t.startY - now.midY
                    t.probes.append((moved, sentNow, Date()))
                    if t.probes.count > 16 { t.probes.removeFirst() }
                    let p = t.probes
                    // How much the page followed the last stretch of scrolling.
                    if p.count >= 2 {
                        let dSent = p[p.count - 1].sent - p[p.count - 2].sent
                        let dMoved = p[p.count - 1].moved - p[p.count - 2].moved
                        if abs(dSent) > 6 { t.ratio = max(0, min(1, dMoved / dSent)) }
                        if t.ratio > 0.7 { self.scrollEdge = 0 }
                    }
                    t.verified = moved
                    // Let the ride catch up to confirmed movement it was holding back.
                    if !t.frozen {
                        let catchUp = max(-40, min(40, moved - t.shown))
                        if abs(catchUp) > 2 {
                            self.marker.shift(by: catchUp)
                            t.shown += catchUp
                        }
                    }
                    if t.frozen {
                        // New text arrived, or the page frees up: follow again from here.
                        if p.count >= 2, abs(p[p.count - 1].moved - p[p.count - 2].moved) > 4 {
                            t.frozen = false
                            t.ratio = 1
                            self.scrollEdge = 0
                            if self.sourceInFront { self.marker.show(now) }
                        }
                    } else if p.count >= 2, abs(p[p.count - 1].moved - p[p.count - 2].moved) < 2,
                              abs(p[p.count - 1].sent - p[p.count - 2].sent) < 2 {
                        // The page and your fingers are both still: trust the
                        // measurement and settle the highlight exactly on the word.
                        if let cur = self.marker.currentRect, abs(cur.midY - now.midY) > 3, self.sourceInFront {
                            self.marker.show(now)
                        }
                    }
                    // The oldest check from 0.35–0.5 s ago: apps like Claude report
                    // text positions up to 0.2 s late, so a shorter window saw a
                    // page that was moving fine as "stopped" and cut glides short.
                    let ago = p.first { let age = Date().timeIntervalSince($0.at); return age >= 0.35 && age <= 0.5 }
                    if !t.frozen, let a = ago, let b = p.last {
                        // The text didn't budge for that long while steps kept
                        // coming: the page has stopped.
                        let stalled = abs(b.moved - a.moved) < 2 && abs(b.sent - a.sent) > 8
                        let behind = abs(sentNow) - abs(moved) > 12
                        if stalled, behind {
                            t.frozen = true
                            self.scrollEdge = t.dir
                            if self.sourceInFront { self.marker.show(now) }
                            if t.glide { self.endGlideEarly(locator, moved: moved) }
                        }
                    }
                    if self.tracking != nil { self.tracking = t }
                }
            }
        }
    }

    /// The page stopped part way through a glide (its end): stop sending steps
    /// and carry on reading.
    private func endGlideEarly(_ locator: WordLocator, moved: CGFloat) {
        scroller.cancel()
        Log.write("highlight: page stopped after \(Int(moved)) px — glide ended there")
        pageStuck = true
        stuckEnd = glideEnd
        gliding = false
        tracking = nil
        findNext()
    }

    private func followUserScroll(_ dy: CGFloat) {
        guard dy != 0, let locator = lastLocator else { return }
        let dir = dy > 0 ? 1 : -1
        if tracking == nil || tracking?.glide == true || tracking?.dir != dir {
            if tracking?.glide == true { scroller.cancel(); gliding = false }  // you took over
            beginTracking(locator, glide: false, dir: dir)
        }
        trackMoved(dy)
    }

    private var settleAfterScroll: DispatchWorkItem?

    private func remeasureMarker() {
        guard let locator = lastLocator, !busy else { return }
        busy = true
        finder.async {
            let box = locator.remeasure()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if let box, self.sourceInFront, self.lastLocator === locator { self.marker.show(box) }
                    self.findNext()
                }
            }
        }
    }

    private func findNext() {
        guard !busy, !gliding, let (word, next, locator) = pending else { return }
        pending = nil
        busy = true
        // Follow the reading by scrolling — unless you're scrolling (or paged)
        // yourself recently, the app isn't in front, or it scrolled just now.
        let userRecently = Date().timeIntervalSince(lastUserScroll) <= settings.autoScrollPause
        if settings.autoScroll, userRecently { stats.waitedForYou += 1 }
        let mayScroll = settings.autoScroll && settings.highlightWords && sourceInFront && !userRecently

        // While you're scrolling, the page keeps moving between measuring a
        // word and drawing it: note how far the ride has gone, to correct by.
        let sentBefore = (tracking?.glide == false) ? tracking?.sent : nil
        finder.async {
            let box = locator.locate(word, next: next)
            let view = box != nil && mayScroll ? locator.visibleArea() : nil
            // Near the bottom: where the page's text ends, so a glide never asks
            // for more than the page can move.
            let nearEnd = view.flatMap { v in box.map { $0.maxY > v.midY } } ?? false
            let bottom = nearEnd ? view.flatMap { locator.pageBottom(below: $0) } : nil
            let end: CGFloat?? = nearEnd ? .some(bottom) : .none
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if var box {
                        if let before = sentBefore, var t = self.tracking, !t.glide {
                            // Still scrolling: shift the measured box by what has
                            // really scrolled past meanwhile (none at the page's
                            // end, however far the fingers went), and ride on.
                            box = box.offsetBy(dx: 0, dy: -(t.sent - before) * (t.frozen ? 0 : t.ratio))
                            t.startY = box.midY
                            t.sent = 0
                            t.shown = 0
                            t.verified = 0
                            t.probes = []
                            self.tracking = t
                        }
                        self.place(box)
                        if let view { self.lastView = view; self.follow(box, in: view, textEnd: end) }
                    } else { self.stats.missed += 1; self.missed() }
                    self.findNext()
                }
            }
        }
    }

    private func missed() {
        // Keep the last spot briefly so one unmatched word doesn't blink.
        if missedSince == nil { missedSince = Date() }
        if let t = missedSince, Date().timeIntervalSince(t) > 0.8 { marker.hide() }
    }

    /// Per reading, for the log: words placed, not found, hidden (app not in front).
    private var stats = (placed: 0, missed: 0, hidden: 0, scrolled: 0, waitedForYou: 0)

    private func hideWord() {
        if stats.placed + stats.missed + stats.hidden + stats.scrolled > 0 {
            Log.write("highlight: \(stats.placed) words shown, \(stats.missed) not found, \(stats.hidden) hidden (other app in front), \(stats.scrolled) auto-scrolls (\(stats.waitedForYou) words while you were scrolling)")
            if let v = lastLocator?.debugView { Log.write("highlight: \(v)") }
            Log.write("highlight: marker \(marker.debugState)")
            stats = (0, 0, 0, 0, 0)
        }
        pending = nil
        lastLocator = nil
        pageStuck = false
        stuckEnd = nil
        glidesGaveUp = false
        ocrStale = false
        lastView = nil
        tracking = nil
        scrollEdge = 0
        lineGap = nil
        lastLineY = nil
        missedSince = nil
        marker.hide()
    }

    /// Only over the app being read: not on top of whatever you switched to.
    private var sourceInFront: Bool {
        guard let pid = lastLocator?.pid, pid > 0 else { return true }
        // Earshot's own windows (tests, the README demo) are right there on screen
        // even when another app is active: never hide their highlight.
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// True once the page scrolled during an OCR reading (boxes are stale).
    private var ocrStale = false

    private func place(_ rect: CGRect) {
        guard !ocrStale else { stats.hidden += 1; return }
        missedSince = nil
        guard sourceInFront else {
            if stats.hidden == 0 {
                let front = NSWorkspace.shared.frontmostApplication
                Log.write("highlight: hidden — \(front?.localizedName ?? "?") (pid \(front?.processIdentifier ?? 0)) is in front, the text is in pid \(lastLocator?.pid ?? 0)")
            }
            stats.hidden += 1; marker.hide(); return
        }
        stats.placed += 1
        marker.tint(for: reader.speedMode, normal: settings.highlightColor.color, style: settings.highlightStyle)
        marker.show(rect)
        captureIfAsked(rect)
    }

    /// Diagnostics: if ~/Library/Logs/Earshot/capture-next exists, the next
    /// placed word is photographed (with the marker) and the flag removed.
    private func captureIfAsked(_ rect: CGRect) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Earshot")
        let flag = dir.appendingPathComponent("capture-next")
        guard FileManager.default.fileExists(atPath: flag.path) else { return }
        try? FileManager.default.removeItem(at: flag)
        let state = marker.debugState
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task {
                Log.write("capture: word at \(rect), marker \(state), front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                guard let content = try? await SCShareableContent.current, let d = content.displays.first else { Log.write("capture: no display"); return }
                let config = SCStreamConfiguration()
                config.sourceRect = rect.insetBy(dx: -220, dy: -120)
                config.width = Int(config.sourceRect.width * 2)
                config.height = Int(config.sourceRect.height * 2)
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: config) else {
                    Log.write("capture: screenshot failed"); return
                }
                let url = dir.appendingPathComponent("capture.png")
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                Log.write("capture: saved \(url.path)")
            }
        }
    }

    /// Debug: shows the word marker over `rect` (to check it's visible).
    func testMarker(_ rect: CGRect) { marker.show(rect) }

    /// Debug: shows the marker with a given look (not saved) and photographs it.
    func testMarkerLook(style: HighlightStyle, color: HighlightColor, rect: CGRect, file: URL) {
        marker.show(rect)
        marker.tint(for: .normal, normal: color.color, style: style)
        marker.show(rect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task {
                guard let content = try? await SCShareableContent.current, let d = content.displays.first else { return }
                let config = SCStreamConfiguration()
                config.sourceRect = rect.insetBy(dx: -40, dy: -14)
                config.width = Int(config.sourceRect.width * 2)
                config.height = Int(config.sourceRect.height * 2)
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: config) {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: file)
                }
                Log.write("marker-look: \(style) \(color) — \(self.marker.debugState)")
                self.marker.hide()
            }
        }
    }
    func testMarkerHide() { marker.hide() }

    /// Outlines `rect` (top-left screen coordinates) for a moment.
    func flash(rect: CGRect) {
        guard settings.highlightSource, rect.width > 4, rect.height > 4 else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: rect.minX - 4, y: primaryHeight - rect.maxY - 4, width: rect.width + 8, height: rect.height + 8)
        let w = highlight ?? {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = HUD.overlayBehavior
            let v = NSView()
            v.wantsLayer = true
            v.layer?.borderWidth = 2.5
            v.layer?.cornerRadius = 6
            v.layer?.borderColor = NSColor.controlAccentColor.cgColor
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            w.contentView = v
            highlight = w
            return w
        }()
        w.setFrame(frame, display: true)
        w.alphaValue = 1
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; w.animator().alphaValue = 0 }) { w.orderOut(nil) }
        }
    }
}

private struct HUDView: View {
    @ObservedObject var reader: Reader
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 22)
                .symbolEffect(.variableColor.iterative, isActive: reader.state == .speaking)
            VStack(alignment: .leading, spacing: 2) {
                Text(reader.notice.map { AttributedString($0) } ?? spokenText)
                    .font(.system(size: 13, weight: reader.notice == nil ? .regular : .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if reader.notice == nil, reader.total > 0 {
                    Text("\(reader.position) of \(reader.total) · \(String(format: "%.2g", reader.speed))×\(reader.speedMode == .boost ? " ⚡" : reader.speedMode == .slow ? " 🐢" : "")")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if reader.isActive {
                HStack(spacing: 4) {
                    button("backward.fill") { reader.skip(-1) }
                    button(reader.state == .paused ? "play.fill" : "pause.fill") { reader.togglePause() }
                    button("forward.fill") { reader.skip(1) }
                    button("xmark") { reader.stop() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 520, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The sentence with the spoken word lit up. Long sentences are shown
    /// from a little before the word so it's always in view.
    private var spokenText: AttributedString {
        let text = reader.currentText as NSString
        guard settings.highlightWordsInBar, let r = reader.spokenRange, NSMaxRange(r) <= text.length else {
            return AttributedString(reader.currentText)
        }
        var start = 0
        if text.length > 110, r.location > 50 {
            start = min(r.location - 40, max(0, text.length - 110))
            let space = text.range(of: " ", range: NSRange(location: start, length: r.location - start))
            if space.location != NSNotFound { start = space.location + 1 }
        }
        let prefix = start > 0 ? "…" : ""
        var out = AttributedString(prefix + text.substring(with: NSRange(location: start, length: r.location - start)))
        var word = AttributedString(text.substring(with: r))
        word.backgroundColor = Color.yellow.opacity(0.45)
        word.font = .system(size: 13, weight: .semibold)
        out += word
        out += AttributedString(text.substring(from: NSMaxRange(r)))
        return out
    }

    private var icon: String {
        if reader.notice != nil && !reader.isActive { return "headphones" }
        switch reader.state {
        case .preparing: return "ellipsis"
        case .paused: return "pause.circle"
        default: return "waveform"
        }
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
    }
}

/// The follow-along marker: a soft highlight with an accent underline that
/// glides from word to word. It lives in one transparent, click-through
/// window over the screen and moves as a Core Animation layer, so each step
/// is a GPU transform rather than a window move.
@MainActor
final class WordMarker {
    private var window: NSWindow?
    private let fill = CALayer()
    private let underline = CALayer()
    private var visible = false
    private var lastRect: CGRect?

    func show(_ rect: CGRect) {
        // Accessibility rects are top-left based; skip off-screen or odd ones.
        guard rect.width > 1, rect.height > 4, rect.height < 120,
              let screen = NSScreen.screens.first(where: { topLeftFrame($0).intersects(rect) }) else { hide(); return }
        let w = window(for: screen)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let pad: CGFloat = 3
        let local = CGRect(x: rect.minX - screen.frame.minX - pad,
                           y: primaryHeight - rect.maxY - screen.frame.minY - 1,
                           width: rect.width + pad * 2, height: rect.height + 2)
        let sameLine = visible && lastRect.map { abs($0.midY - rect.midY) < rect.height * 0.5 } == true
        CATransaction.begin()
        if sameLine {
            CATransaction.setAnimationDuration(0.07)  // quick, so it never looks smeared between words
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)  // new line: jump, then fade in
        }
        layout(local)
        CATransaction.commit()
        if visible, !w.isVisible || !w.isOnActiveSpace {
            // The system took the marker window away, or left it on another
            // desktop after a swipe: re-showing it doesn't move it between
            // desktops, so start over with a fresh window on this one.
            Log.write("highlight: marker window was \(w.isVisible ? "on another desktop" : "hidden by the system") — making a new one here")
            rebuild()
            show(rect)
            return
        }
        if !visible {
            w.orderFrontRegardless()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            fill.opacity = 1
            underline.opacity = 1
            CATransaction.commit()
            visible = true
        } else if !sameLine {
            fadeIn()
        }
        lastRect = rect
    }

    /// Accent colour at normal speed, orange while fast, teal while slow.
    /// Bold enough to follow at a glance on dark and light pages (the old 22%
    /// accent tint all but vanished on dark backgrounds): a strong fill, a
    /// solid underline and a thin border. Normal speed uses the chosen colour,
    /// fast is orange, slow is teal.
    func tint(for mode: Reader.SpeedMode, normal: NSColor = .systemYellow, style: HighlightStyle = .bold) {
        let color: NSColor = switch mode {
        case .normal: normal
        case .boost: .systemOrange
        case .slow: .systemTeal
        }
        guard color != tintColor || style != tintStyle else { return }
        tintColor = color
        tintStyle = style
        let bold = style == .bold
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        // Soft is the original look: a light tint and a thin underline.
        fill.backgroundColor = color.withAlphaComponent(bold ? 0.42 : 0.22).cgColor
        fill.borderColor = color.withAlphaComponent(0.95).cgColor
        fill.borderWidth = bold ? 1.5 : 0
        underline.backgroundColor = color.withAlphaComponent(bold ? 1 : 0.95).cgColor
        underlineHeight = bold ? 3 : 2.5
        CATransaction.commit()
    }
    private var tintStyle: HighlightStyle?
    private var underlineHeight: CGFloat = 3
    private var tintColor: NSColor?

    /// Where the marker is now (top-left screen coordinates).
    var currentRect: CGRect? { visible ? lastRect : nil }

    /// Moves the marker up by `dy` points (as the page scrolls under it).
    func shift(by dy: CGFloat) {
        guard visible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame.origin.y += dy
        underline.frame.origin.y += dy
        CATransaction.commit()
        lastRect = lastRect?.offsetBy(dx: 0, dy: -dy)
    }

    /// Debug: what the marker window is doing.
    var debugState: String {
        guard let w = window else { return "no window yet" }
        return "window visible \(w.isVisible), on active space \(w.isOnActiveSpace), frame \(w.frame), level \(w.level.rawValue), layer frame \(fill.frame), opacity \(fill.opacity)"
    }

    func hide() {
        guard visible else { return }
        visible = false
        lastRect = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { if self?.visible == false { self?.window?.orderOut(nil) } }
        }
        fill.opacity = 0
        underline.opacity = 0
        CATransaction.commit()
    }

    private func layout(_ r: CGRect) {
        fill.frame = r
        fill.cornerRadius = min(6, r.height * 0.3)
        underline.frame = CGRect(x: r.minX + 1, y: r.minY - 2, width: r.width - 2, height: underlineHeight)
    }

    private func fadeIn() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.2
        a.toValue = 1
        a.duration = 0.12
        fill.add(a, forKey: "fade")
        underline.add(a, forKey: "fade")
    }

    func newDesktop() { rebuild() }

    /// Drops the marker window so the next show makes a new one on the
    /// desktop you're on now.
    private func rebuild() {
        fill.removeFromSuperlayer()
        underline.removeFromSuperlayer()
        fill.removeAllAnimations()
        underline.removeAllAnimations()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        visible = false
        lastRect = nil
    }

    private func window(for screen: NSScreen) -> NSWindow {
        if let w = window, w.frame == screen.frame { return w }
        let w = window ?? {
            // A non-activating panel: the kind macOS lets onto every desktop,
            // full-screen ones included.
            let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.collectionBehavior = HUD.overlayBehavior
            let v = NSView()
            v.wantsLayer = true
            // Colours come from tint(for:) only — setting a default here used to
            // overwrite the chosen colour the first time the window was made.
            fill.opacity = 0
            underline.cornerRadius = 1.5
            underline.opacity = 0
            v.layer?.addSublayer(fill)
            v.layer?.addSublayer(underline)
            w.contentView = v
            window = w
            return w
        }()
        w.setFrame(screen.frame, display: false)
        return w
    }

    private func topLeftFrame(_ s: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
    }
}

/// Scrolls an app smoothly, like a trackpad: many small pixel scroll steps
/// over a short time with ease-in-out. Each step is an ordinary scroll at the
/// pointer's current spot (apps like Claude and Brave ignore scrolls sent any
/// other way), so the pointer itself never moves. It only scrolls while the
/// pointer rests over the page being read, and steps are tagged so Earshot's
/// own scroll watcher can tell them from yours.
@MainActor
final class SmoothScroller {
    static let tag: Int64 = 0x4541_5253  // "EARS"
    private var timer: Timer?
    private(set) var isBusy = false

    /// Whether a glide can run now: the pointer is over `view` in the app's
    /// own window (nothing else on top).
    static func canScroll(pid: pid_t, view: CGRect) -> Bool {
        guard let mouse = CGEvent(source: nil)?.location, view.insetBy(dx: 2, dy: 2).contains(mouse) else { return false }
        return windowOwner(at: mouse) == pid
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        isBusy = false
    }

    /// `dy` > 0 moves the content up (shows what's below). A gentle sine
    /// ease-in-out, stepped at 120 Hz. `step` gets each step's size and the
    /// total so far, as it's sent. Stops early if the pointer leaves the page.
    func scroll(by dy: CGFloat, pid: pid_t, view: CGRect, duration: Double, easing: String = "inOut",
                step: @escaping (CGFloat, CGFloat) -> Void, done: @escaping () -> Void) {
        timer?.invalidate()
        let start = Date()
        var sent: CGFloat = 0
        isBusy = true
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.timer === t else { t.invalidate(); return }
                let p = min(1, Date().timeIntervalSince(start) / duration)
                let eased: Double = switch easing {
                case "out": 1 - pow(1 - p, 3)             // moves off briskly, settles slowly
                case "steady": p                          // the same pace throughout
                default: (1 - cos(.pi * p)) / 2           // starts and ends softly
                }
                let goal = (dy * eased).rounded()
                let delta = goal - sent
                var ok = true
                if delta != 0 {
                    ok = Self.post(-delta, pid: pid, view: view)
                    if ok { sent = goal; step(delta, sent) }
                }
                if p >= 1 || !ok { self.cancel(); done() }
            }
        }
        RunLoop.main.add(t, forMode: .common)  // keeps gliding while menus or drags track
        timer = t
    }

    /// One scroll step at the pointer, only while it's over the page.
    @discardableResult
    static func post(_ pixels: CGFloat, pid: pid_t, view: CGRect) -> Bool {
        guard let mouse = CGEvent(source: nil)?.location, view.contains(mouse),
              let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                              wheel1: Int32(pixels), wheel2: 0, wheel3: 0) else { return false }
        e.location = mouse
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.post(tap: .cghidEventTap)
        return true
    }

    /// The app owning the frontmost ordinary window at `point` (top-left coordinates).
    static func windowOwner(at point: CGPoint) -> pid_t? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.contains(point) else { continue }
            return w[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }
}

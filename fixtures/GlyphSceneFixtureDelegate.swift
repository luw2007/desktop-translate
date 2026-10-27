// Window/delegate half of the standalone GLYPH-SCENE fixture (see GlyphSceneFixtureApp.swift).
//
// Owns the window, the phase timer, the exit-file/owner-PID watchdog and the manifest publish loop. It never
// activates the app, posts events, installs an event tap, or uses Accessibility; it publishes only fixed public
// text, rectangles, scales and event-TYPE counts. Scene specs come from GlyphSceneFixtureApp.swift and drawing
// from GlyphSceneFixtureDrawing.swift.
//
// Built by fixtures/build-glyph-fixture.sh.
import AppKit
import CoreText

@MainActor
final class GlyphDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let view = GlyphView()
    var scene = "boundary", phase = "stable", title = "Glyph Fixture"
    var period = 1.0
    var manifestPath = "", exitFile: String?, ownerPID: pid_t?
    var frame = CGRect(x: 80, y: 80, width: 640, height: 400)
    var decorationsBase: [CGRect] = []
    var revision = 0, sequence = 0, mutated = false, caretVisible = false
    var caretTicks = 0
    var tokens: [GlyphToken] = []
    var timer: Timer?

    init(arguments a: [String]) {
        super.init()
        var i = 0
        func value() -> String { i += 1; guard i < a.count else { fail("missing value for \(a[i - 1])") }; return a[i] }
        while i < a.count {
            switch a[i] {
            case "--manifest": manifestPath = value()
            case "--scene": scene = value()
            case "--phase": phase = value()
            case "--period": period = Double(value()) ?? 1.0
            case "--title": title = value()
            case "--exit-file": exitFile = value()
            case "--owner-pid": ownerPID = pid_t(value())
            case "--frame":
                let n = value().split(separator: ",").compactMap { Double($0) }
                guard n.count == 4, n[2] > 0, n[3] > 0 else { fail("bad --frame") }
                frame = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
            default: fail("unknown argument \(a[i])")
            }
            i += 1
        }
        guard !manifestPath.isEmpty else { fail("--manifest is required") }
        guard ["stable", "mutate", "caret"].contains(phase) else { fail("bad --phase") }
        guard period >= 0.05 else { fail("--period too small") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let primary = NSScreen.screens.first else { fail("no screen available") }
        let primaryH = primary.frame.height
        let appKitFrame = CGRect(x: frame.minX, y: primaryH - frame.minY - frame.height, width: frame.width, height: frame.height)
        window = NSWindow(contentRect: appKitFrame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrame(appKitFrame, display: false)   // requested rect is the FULL window frame, like PublicFixture
        window.sharingType = .readOnly                 // explicit default: window must be capturable (never .none)
        window.contentView = view
        guard let built = sceneSpecs(scene, size: view.bounds.size) else { fail("unknown --scene \(scene)") }
        view.specs = built.specs
        decorationsBase = built.decorations
        view.decorations = decorationsBase
        view.onChange = { [weak self] in self?.publish() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        updateDisplay()
        timer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
    }

    func watch() {
        if let f = exitFile, FileManager.default.fileExists(atPath: f) { NSApp.terminate(nil) }
        if let p = ownerPID, kill(p, 0) != 0 && errno == ESRCH { NSApp.terminate(nil) }
    }

    func tick() {
        switch phase {
        case "mutate":
            mutated.toggle()
            var changed = false
            for t in view.specs {
                guard let alt = t.alt else { continue }
                let text = mutated ? alt : t.text
                if (view.texts[t.id] ?? t.text) != text {
                    view.texts[t.id] = text
                    changed = true
                }
            }
            guard changed else { return }
            revision += 1
        case "caret":
            caretTicks += 1
            caretVisible = caretTicks < 4 && caretTicks % 2 == 1
            if caretTicks >= 4 {
                phase = "caret-stop"
                timer?.invalidate()
            }
        default: return
        }
        updateDisplay()
    }

    func updateDisplay() {
        refreshTokens()
        view.caret = nil
        if caretVisible, let ink = view.inkBounds.last {
            let width = min(2, ink.width)
            view.caret = CGRect(x: ink.maxX - width, y: ink.minY, width: width, height: ink.height)
        }
        view.needsDisplay = true
        view.displayIfNeeded()
        publish()
    }

    /// Recompute glyph + oracle ink for the current texts at the actual backing scale.
    func refreshTokens() {
        let scale = Double(window.backingScaleFactor)
        let inset = window.frame.height - window.contentLayoutRect.height
        let size = view.bounds.size
        let off = CGPoint(x: 0, y: inset)
        func local(_ r: CGRect) -> GlyphRect { GlyphRect(r.offsetBy(dx: off.x, dy: off.y)) }
        var out: [GlyphToken] = []
        var lines: [String: CTLine] = [:]
        var inkBounds: [CGRect] = []
        let ordered = view.specs.enumerated().sorted { ($0.element.origin.y.rounded(), $0.element.origin.x) < ($1.element.origin.y.rounded(), $1.element.origin.x) }
        for (rank, pair) in ordered.enumerated() {
            let t = pair.element
            let text = view.texts[t.id] ?? t.text
            let line = makeLine(text, font: t.font)
            lines[t.id] = line
            let ink = alphaInkBounds(line, at: t.origin, contentSize: size, scale: scale)
            if let ink { inkBounds.append(ink) }
            out.append(GlyphToken(id: t.id, group: t.group, text: text, order: rank, line: t.line, container: local(t.container),
                                  glyph: local(glyphBounds(line, at: t.origin)), ink: ink.map(local), mutates: t.alt != nil))
        }
        tokens = out
        view.lines = lines
        view.inkBounds = inkBounds
    }

    func publish() {
        guard let primary = NSScreen.screens.first, let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              number.uint32Value != 0 else { return }
        sequence += 1
        let primaryH = primary.frame.height
        let wf = window.frame
        let quartz = GlyphGeometry.quartz(fromAppKit: wf, primaryScreenHeight: primaryH)
        let displayID = number.uint32Value
        let displayBounds = CGDisplayBounds(displayID)
        let inset = wf.height - window.contentLayoutRect.height
        let m = GlyphScene(sceneID: scene, runRevision: revision, phase: phase, caretVisible: caretVisible, sequence: sequence,
                           pid: getpid(), bundleID: Bundle.main.bundleIdentifier ?? "", windowID: UInt32(window.windowNumber),
                           frameQuartz: GlyphRect(quartz), contentTopInset: inset, backingScale: Double(window.backingScaleFactor),
                           displayID: displayID, displayFrameQuartz: GlyphRect(displayBounds),
                           displayScale: Double(screen.backingScaleFactor), isActive: NSApp.isActive, tokens: tokens,
                           decorations: (view.decorations + (view.caret.map { [$0] } ?? [])).map { GlyphRect($0.offsetBy(dx: 0, dy: inset)) },
                           observer: view.counts)
        guard let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
    }

    func applicationDidBecomeActive(_ n: Notification) { view.counts.becomeActive += 1; if window != nil { publish() } }
    func applicationDidResignActive(_ n: Notification) { view.counts.resignActive += 1; if window != nil { publish() } }
    func windowDidMove(_ n: Notification) { updateDisplay() }
    func windowDidResize(_ n: Notification) {
        guard let built = sceneSpecs(scene, size: view.bounds.size) else { return }
        view.specs = built.specs
        decorationsBase = built.decorations
        view.decorations = decorationsBase
        updateDisplay()
    }
    func windowDidChangeScreen(_ n: Notification) { updateDisplay() }
    func windowDidChangeBackingProperties(_ n: Notification) { updateDisplay() }
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

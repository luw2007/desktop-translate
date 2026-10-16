// Standalone public GLYPH-SCENE fixture for Desktop Translate verification (independent of PublicFixtureApp.swift).
//
// Separate app: own bundle, own PID. Draws only fixed public sample text. Every token is drawn with CoreText
// at a known baseline; its genuine glyph-ink bounds are published two ways:
//   glyph = CTLineGetBoundsWithOptions(.useGlyphPathBounds) (typographic path bounds, exact drawn string)
//   ink   = tight bounds of alpha > threshold from an IN-MEMORY alpha-only bitmap render of that same token
//           at the window's real backing scale (oracle). No image/pixel/text hash is ever written to disk.
// It never posts events, installs no event tap, uses no Accessibility, never calls NSApp.activate (natural
// LaunchServices launch only), and records only event TYPE counts and a coarse glyph-ink zone.
//
// Build: fixtures/build-glyph-fixture.sh. Shares GlyphSceneManifest.swift (schema + pure geometry).
//
// Arguments:
//   --manifest <path>    JSON GlyphScene rewritten on every change (required)
//   --scene <id>         boundary | collision | icon | code | cjk | prose   (default boundary)
//   --phase <p>          stable | mutate | caret   (default stable)
//   --period <seconds>   deterministic phase timer period (default 1.0)
//   --frame x,y,w,h      window frame, Quartz desktop points, top-left origin (default 80,80,640,400)
//   --title <text>       window title
//   --exit-file <path>   quit once this file exists
//   --owner-pid <pid>    quit if this process disappears
//
// Phases: stable = nothing changes. mutate = every `period`, tokens with mutates=true swap text and
// runRevision++. caret = four caret ticks followed by a hidden, stable caret-stop; runRevision never changes.
import AppKit
import CoreText

struct TokenSpec {
    var id: String, group: String, text: String, alt: String?
    var font: NSFont
    var origin: CGPoint        // baseline-left, content-view coordinates (top-left origin)
    var container: CGRect      // content-view coordinates
    var line = 0
}

private func sys(_ s: CGFloat) -> NSFont { .systemFont(ofSize: s) }
private func mono(_ s: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: s, weight: .regular) }

func sceneSpecs(_ scene: String, size: CGSize) -> (specs: [TokenSpec], decorations: [CGRect])? {
    var s: [TokenSpec] = []
    var d: [CGRect] = []
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
    switch scene {
    case "boundary":
        // Tokens hugging container edges and the content-view edges.
        s = [
            TokenSpec(id: "boundary.top.1", group: "boundary", text: "Top edge label", alt: nil, font: sys(15), origin: CGPoint(x: 2, y: 17), container: box(0, 0, 200, 22)),
            TokenSpec(id: "boundary.left.1", group: "boundary", text: "Left flush text", alt: nil, font: sys(14), origin: CGPoint(x: 0, y: 70), container: box(0, 50, 180, 28)),
            TokenSpec(id: "boundary.right.1", group: "boundary", text: "Right edge text", alt: nil, font: sys(14), origin: CGPoint(x: size.width - 118, y: 110), container: box(size.width - 120, 90, 120, 28)),
            TokenSpec(id: "boundary.descender.1", group: "boundary", text: "gypsy jqpy quip", alt: nil, font: sys(18), origin: CGPoint(x: 20, y: 170), container: box(10, 148, 220, 32)),
            TokenSpec(id: "boundary.tight.1", group: "boundary", text: "Tight box", alt: "Tight cell", font: sys(13), origin: CGPoint(x: 252, y: 170), container: box(250, 156, 70, 18)),
            TokenSpec(id: "boundary.bottom.1", group: "boundary", text: "Bottom edge label", alt: nil, font: sys(15), origin: CGPoint(x: 6, y: size.height - 4), container: box(0, size.height - 24, 220, 24)),
        ]
    case "collision":
        // Adjacent runs, tight leading, and near-touching neighbours: strict 1:1 must not merge or swap them.
        s = [
            TokenSpec(id: "collision.a.1", group: "collision", text: "Alpha", alt: "Apple", font: sys(20), origin: CGPoint(x: 20, y: 60), container: box(18, 36, 70, 30), line: 0),
            TokenSpec(id: "collision.a.2", group: "collision", text: "Beta", alt: nil, font: sys(20), origin: CGPoint(x: 92, y: 60), container: box(90, 36, 60, 30), line: 0),
            TokenSpec(id: "collision.a.3", group: "collision", text: "Gamma", alt: nil, font: sys(20), origin: CGPoint(x: 154, y: 60), container: box(152, 36, 80, 30), line: 0),
            TokenSpec(id: "collision.b.1", group: "collision", text: "Tight leading one", alt: nil, font: sys(16), origin: CGPoint(x: 20, y: 120), container: box(18, 106, 220, 18), line: 0),
            TokenSpec(id: "collision.b.2", group: "collision", text: "Tight leading two", alt: nil, font: sys(16), origin: CGPoint(x: 20, y: 136), container: box(18, 124, 220, 16), line: 1),
            TokenSpec(id: "collision.b.3", group: "collision", text: "Tight leading three", alt: nil, font: sys(16), origin: CGPoint(x: 20, y: 152), container: box(18, 140, 220, 16), line: 2),
            TokenSpec(id: "collision.c.1", group: "collision", text: "Cancel", alt: nil, font: sys(14), origin: CGPoint(x: 280, y: 60), container: box(270, 40, 70, 28)),
            TokenSpec(id: "collision.c.2", group: "collision", text: "Cancel", alt: nil, font: sys(14), origin: CGPoint(x: 420, y: 60), container: box(410, 40, 70, 28)),
        ]
    case "icon":
        s = [
            TokenSpec(id: "icon.save.1", group: "icon", text: "Save changes", alt: nil, font: sys(15), origin: CGPoint(x: 52, y: 60), container: box(10, 36, 180, 34)),
            TokenSpec(id: "icon.open.1", group: "icon", text: "Open folder", alt: nil, font: sys(15), origin: CGPoint(x: 52, y: 110), container: box(10, 86, 180, 34)),
            TokenSpec(id: "icon.star.1", group: "icon", text: "★ Favorites ✓", alt: nil, font: sys(15), origin: CGPoint(x: 20, y: 160), container: box(10, 136, 180, 34)),
            TokenSpec(id: "icon.badge.1", group: "icon", text: "Inbox", alt: nil, font: sys(14), origin: CGPoint(x: 52, y: 210), container: box(10, 190, 120, 28)),
        ]
        d = [box(18, 44, 24, 24), box(18, 94, 24, 24), box(18, 196, 24, 24), box(100, 196, 18, 18)]
    case "code":
        s = [
            TokenSpec(id: "code.line.1", group: "code", text: "let total = items.map { $0.count }.reduce(0, +)", alt: nil, font: mono(13), origin: CGPoint(x: 16, y: 50), container: box(10, 34, 560, 22), line: 0),
            TokenSpec(id: "code.line.2", group: "code", text: "if (a[i] != b[j]) { return -1; }", alt: nil, font: mono(13), origin: CGPoint(x: 16, y: 74), container: box(10, 58, 560, 22), line: 1),
            TokenSpec(id: "code.line.3", group: "code", text: "$ git commit -m \"fix: handle {} and [] pairs\"", alt: nil, font: mono(13), origin: CGPoint(x: 16, y: 98), container: box(10, 82, 560, 22), line: 2),
            TokenSpec(id: "code.line.4", group: "code", text: "https://example.com/a_b/c.d?x=1&y=2", alt: nil, font: mono(13), origin: CGPoint(x: 16, y: 122), container: box(10, 106, 560, 22), line: 3),
        ]
    case "cjk":
        s = [
            TokenSpec(id: "cjk.zh.1", group: "cjk", text: "你好，世界。这是一个测试。", alt: nil, font: sys(18), origin: CGPoint(x: 20, y: 56), container: box(10, 30, 420, 34)),
            TokenSpec(id: "cjk.ja.1", group: "cjk", text: "こんにちは世界、テストです。", alt: nil, font: sys(18), origin: CGPoint(x: 20, y: 106), container: box(10, 80, 420, 34)),
            TokenSpec(id: "cjk.ko.1", group: "cjk", text: "안녕하세요 세계 테스트", alt: nil, font: sys(18), origin: CGPoint(x: 20, y: 156), container: box(10, 130, 420, 34)),
            TokenSpec(id: "cjk.mix.1", group: "cjk", text: "Mixed 中文 and English 文本", alt: nil, font: sys(16), origin: CGPoint(x: 20, y: 206), container: box(10, 184, 420, 30)),
            TokenSpec(id: "cjk.combining.1", group: "cjk", text: "Cafe\u{0301} nai\u{0308}ve a\u{0323}\u{0301}", alt: nil, font: sys(18), origin: CGPoint(x: 20, y: 256), container: box(10, 230, 420, 34)),
        ]
    case "prose":
        s = [
            TokenSpec(id: "prose.heading.1", group: "prose", text: "Public Fixture Heading", alt: nil, font: .boldSystemFont(ofSize: 22), origin: CGPoint(x: 20, y: 52), container: box(10, 20, 420, 40)),
            TokenSpec(id: "prose.line.1", group: "prose", text: "The quick brown fox jumps over the lazy dog.", alt: "The slow green fox walks past the busy dog.", font: sys(14), origin: CGPoint(x: 20, y: 96), container: box(10, 80, 520, 22), line: 0),
            TokenSpec(id: "prose.line.2", group: "prose", text: "Pack my box with five dozen liquor jugs.", alt: nil, font: sys(14), origin: CGPoint(x: 20, y: 120), container: box(10, 104, 520, 22), line: 1),
            TokenSpec(id: "prose.line.3", group: "prose", text: "Sphinx of black quartz, judge my vow.", alt: nil, font: sys(14), origin: CGPoint(x: 20, y: 144), container: box(10, 128, 520, 22), line: 2),
        ]
    default: return nil
    }
    return (s, d)
}

/// Pure token drawing shared by the real view and the alpha oracle so both render the identical CTLine.
func makeLine(_ text: String, font: NSFont) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
}

/// Draw one token into a top-left-origin (flipped) context at baseline `origin`.
func drawToken(_ line: CTLine, at origin: CGPoint, in ctx: CGContext) {
    ctx.saveGState()
    ctx.setShouldAntialias(true)
    ctx.setShouldSmoothFonts(false)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// Typographic glyph path bounds in flipped view coordinates.
func glyphBounds(_ line: CTLine, at origin: CGPoint) -> CGRect {
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    return CGRect(x: origin.x + b.minX, y: origin.y - b.maxY, width: b.width, height: b.height)
}

/// Alpha oracle: renders ONLY this token into a fresh alpha-only bitmap sized to the content area at `scale`
/// and returns the tight ink bounds (alpha >= threshold) in content points, or nil if nothing was painted.
func alphaInkBounds(_ line: CTLine, at origin: CGPoint, contentSize: CGSize, scale: Double, threshold: UInt8 = 24) -> CGRect? {
    let pw = Int((contentSize.width * scale).rounded(.up)), ph = Int((contentSize.height * scale).rounded(.up))
    guard pw > 0, ph > 0 else { return nil }
    var data = [UInt8](repeating: 255, count: pw * ph)   // gray bitmap, white background; ink = darkness
    let (minX, minY, maxX, maxY): (Int, Int, Int, Int) = data.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return (1, 1, 0, 0) }
        // Bitmap rows run bottom-up in CG; flip so that point (0,0) is the top-left like the view.
        ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        // Antialiasing and font smoothing are configured by the shared drawToken path.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        drawToken(line, at: origin, in: ctx)
        var x0 = pw, y0 = ph, x1 = -1, y1 = -1
        let p = raw.bindMemory(to: UInt8.self)
        for row in 0..<ph {
            // Memory row 0 is the TOP row of the image for a CGBitmapContext (y flipped by the CTM already applied).
            for col in 0..<pw where 255 - p[row * pw + col] >= threshold {
                if col < x0 { x0 = col }; if col > x1 { x1 = col }
                if row < y0 { y0 = row }; if row > y1 { y1 = row }
            }
        }
        return (x0, y0, x1, y1)
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let s = CGFloat(scale)
    return CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s, width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
}

final class GlyphView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var specs: [TokenSpec] = []
    var texts: [String: String] = [:]
    var lines: [String: CTLine] = [:]
    var inkBounds: [CGRect] = []
    var decorations: [CGRect] = []
    var caret: CGRect?
    var counts = GlyphObserverCounts()
    var onChange: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill(); bounds.fill()
        ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
        for r in decorations { ctx.fill(r) }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for t in specs {
            if let line = lines[t.id] { drawToken(line, at: t.origin, in: ctx) }
        }
        if let c = caret { ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(c) }
    }
    private func zone(_ e: NSEvent) -> String {
        let p = convert(e.locationInWindow, from: nil)
        return inkBounds.contains { $0.contains(p) } ? "covered" : "uncovered"
    }
    private func bump(_ e: NSEvent, type: String) { counts.zones["\(type).\(zone(e))", default: 0] += 1 }
    override func mouseDown(with event: NSEvent) { counts.mouseDown += 1; bump(event, type: "mouseDown"); onChange?() }
    override func scrollWheel(with event: NSEvent) { counts.scroll += 1; bump(event, type: "scroll"); onChange?() }
    // Only the event TYPE is counted: no characters, no key codes.
    override func keyDown(with event: NSEvent) { counts.keyDown += 1; counts.zones["keyDown.keyboard", default: 0] += 1; onChange?() }
}

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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

@main
struct GlyphSceneFixtureMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = GlyphDelegate(arguments: Array(CommandLine.arguments.dropFirst()))
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

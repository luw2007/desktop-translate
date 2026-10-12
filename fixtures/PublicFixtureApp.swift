// Standalone public fixture process for Desktop Translate verification.
//
// It is a separate app (own bundle, own PID) that draws only public, fixed sample text at a known frame.
// It shares no code with the translator, never activates itself unless `--activate` is passed, never posts
// events to other apps and never touches focus. Capture baselines must come from this independent process,
// never from the excluded translator UI.
//
// Build (see PublicFixture.swift for the bundle contract):
//   swiftc -parse-as-library fixtures/PublicFixtureApp.swift -o "Public Fixture.app/Contents/MacOS/public-fixture" -framework AppKit
//
// Arguments:
//   --manifest <path>   JSON manifest rewritten on every frame/counter change (required)
//   --frame x,y,w,h     window frame in Quartz desktop points (top-left origin, negative values allowed)
//   --title <text>      window title (default "Public Fixture")
//   --black             fill the content solid black without text (all-black refusal evidence)
//   --sharing-none      NSWindow.sharingType = .none (protected-window evidence)
//   --activate          activate this app once after showing (otherwise the launcher decides)
//   --no-text           draw the frame with nothing but a background (no-text evidence)
//
// Manifest rectangles are window-local points, top-left origin, relative to the full window frame
// (title bar included) - the same space as the translator's window-local selection.
import AppKit

struct FixtureRect: Codable { var x: Double; var y: Double; var w: Double; var h: Double }

struct FixtureItem: Codable {
    var id: String
    var text: String
    var kind: String        // heading | label | code | button | cell | paragraph
    var rect: FixtureRect   // window-local points, top-left origin
}

struct FixtureManifest: Codable {
    var schema = 1
    var pid: Int32 = 0
    var bundleID = ""
    var windowID: UInt32 = 0
    var frameQuartz = FixtureRect(x: 0, y: 0, w: 0, h: 0)
    var contentTopInset: Double = 0
    var backingScale: Double = 1
    var displayID: UInt32 = 0
    var mode = "text"
    var items: [FixtureItem] = []
    var mouseDownCount = 0
    var scrollCount = 0
    var keyDownCount = 0
    var buttonPressCount = 0
    var resignActiveCount = 0
    var isActive = false
    var sequence = 0
}

final class FixtureView: NSView {
    override var isFlipped: Bool { true }
    var mode = "text"
    var items: [FixtureItem] = []          // content-view coordinates (top-left origin)
    var counters: (mouse: Int, scroll: Int, key: Int) = (0, 0, 0) { didSet { onChange?() } }
    var onChange: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    static let paragraph = "This paragraph wraps inside a fixed box so that several lines of ordinary English sit together for soft line merging."
    static let paragraphWidth: CGFloat = 360

    override func draw(_ dirtyRect: NSRect) {
        (mode == "black" ? NSColor.black : NSColor.white).setFill()
        bounds.fill()
        guard mode == "text" else { return }
        for item in items where item.kind != "button" {
            let rect = NSRect(x: item.rect.x, y: item.rect.y, width: item.rect.w, height: item.rect.h)
            item.text.draw(with: rect, options: [.usesLineFragmentOrigin], attributes: FixtureView.attributes(kind: item.kind))
        }
        NSColor(white: 0.55, alpha: 1).setStroke()
        for item in items where item.kind == "cell" {
            NSBezierPath(rect: NSRect(x: item.rect.x - 6, y: item.rect.y - 4, width: item.rect.w + 12, height: item.rect.h + 8)).stroke()
        }
    }

    static func attributes(kind: String) -> [NSAttributedString.Key: Any] {
        let font: NSFont
        switch kind {
        case "heading": font = .systemFont(ofSize: 30, weight: .bold)
        case "code": font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        case "paragraph": font = .systemFont(ofSize: 20)
        default: font = .systemFont(ofSize: 22)
        }
        return [.font: font, .foregroundColor: NSColor.black]
    }

    override func mouseDown(with event: NSEvent) { counters.mouse += 1 }
    override func scrollWheel(with event: NSEvent) { counters.scroll += 1 }
    override func keyDown(with event: NSEvent) { counters.key += 1 }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let arguments: [String]
    var window: NSWindow!
    let view = FixtureView()
    var manifest = FixtureManifest()
    var manifestPath = ""
    var buttonPresses = 0
    var resignCount = 0
    var timer: Timer?

    init(arguments: [String]) { self.arguments = arguments }

    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

        guard let path = option("--manifest") else { fail("--manifest <path> is required") }
        manifestPath = path
        let mode = arguments.contains("--black") ? "black" : (arguments.contains("--no-text") ? "empty" : "text")
        view.mode = mode
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var quartz = CGRect(x: 120, y: 120, width: 760, height: 520)
        if let spec = option("--frame") {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4, parts[2] >= 200, parts[3] >= 200 else { fail("--frame needs x,y,w,h with w,h >= 200") }
            quartz = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        let appKitFrame = NSRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
        let style: NSWindow.StyleMask = mode == "black" ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable]
        window = NSWindow(contentRect: appKitFrame, styleMask: style, backing: .buffered, defer: false)
        window.title = option("--title") ?? "Public Fixture"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view
        // contentRect above is a content rect; force the full window frame to the requested one.
        window.setFrame(appKitFrame, display: false)
        if arguments.contains("--sharing-none") { window.sharingType = .none }
        view.onChange = { [weak self] in self?.writeManifest() }
        layoutItems()
        window.orderFrontRegardless()
        if arguments.contains("--activate") || ProcessInfo.processInfo.environment["DESKTOP_TRANSLATE_FIXTURE_ACTIVATE"] == "1" { NSApp.activate(ignoringOtherApps: true) }
        window.makeFirstResponder(view)
        // Frame changes made by the user or the system rewrite the manifest; cheap, content is public.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeManifest(onlyIfChanged: true) }
        }
        writeManifest()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowDidResize(_ notification: Notification) { layoutItems(); writeManifest() }
    func windowDidMove(_ notification: Notification) { writeManifest() }
    func windowDidResignKey(_ notification: Notification) { resignCount += 1; writeManifest() }
    func windowDidBecomeKey(_ notification: Notification) { writeManifest() }

    @objc func buttonPressed(_ sender: NSButton) { buttonPresses += 1; writeManifest() }

    var titleInset: CGFloat { window.frame.height - view.bounds.height }

    /// Content-view layout; every item rect is later shifted by the title-bar inset into window-local space.
    func layoutItems() {
        view.subviews.forEach { $0.removeFromSuperview() }
        guard view.mode == "text" else { view.items = []; view.needsDisplay = true; return }
        func textRect(_ text: String, kind: String, x: CGFloat, y: CGFloat, width: CGFloat? = nil) -> NSRect {
            let attributes = FixtureView.attributes(kind: kind)
            if let width {
                let box = (text as NSString).boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin], attributes: attributes)
                return NSRect(x: x, y: y, width: width, height: ceil(box.height))
            }
            let size = (text as NSString).size(withAttributes: attributes)
            return NSRect(x: x, y: y, width: ceil(size.width), height: ceil(size.height))
        }
        var items: [FixtureItem] = []
        func add(_ id: String, _ text: String, _ kind: String, _ rect: NSRect) {
            items.append(FixtureItem(id: id, text: text, kind: kind, rect: FixtureRect(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)))
        }
        add("heading", "Public Fixture Window", "heading", textRect("Public Fixture Window", kind: "heading", x: 24, y: 20))
        add("sentence", "The quick brown fox jumps over the lazy dog.", "label", textRect("The quick brown fox jumps over the lazy dog.", kind: "label", x: 24, y: 76))
        add("chinese", "你好，世界", "label", textRect("你好，世界", kind: "label", x: 24, y: 118))
        add("code", "npm test --coverage", "code", textRect("npm test --coverage", kind: "code", x: 24, y: 160))
        add("paragraph", FixtureView.paragraph, "paragraph", textRect(FixtureView.paragraph, kind: "paragraph", x: 24, y: 204, width: FixtureView.paragraphWidth))
        add("cell-name", "Name", "cell", textRect("Name", kind: "label", x: 440, y: 84, width: 120))
        add("cell-value", "Value", "cell", textRect("Value", kind: "label", x: 600, y: 84, width: 120))
        let buttonY = max(view.bounds.height - 60, 340)
        var x: CGFloat = 24
        for title in ["Cancel", "Settings", "OK"] {
            let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 18)
            button.sizeToFit()
            let width = max(button.frame.width + 20, 110)
            button.frame = NSRect(x: x, y: buttonY, width: width, height: 36)
            view.addSubview(button)
            add("button-\(title.lowercased())", title, "button", button.frame)
            x += width + 16
        }
        view.items = items
        view.needsDisplay = true
    }

    func writeManifest(onlyIfChanged: Bool = false) {
        guard window != nil else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = window.frame
        var next = manifest
        next.pid = ProcessInfo.processInfo.processIdentifier
        next.bundleID = Bundle.main.bundleIdentifier ?? ""
        next.windowID = UInt32(window.windowNumber)
        next.frameQuartz = FixtureRect(x: frame.minX, y: primaryHeight - frame.maxY, w: frame.width, h: frame.height)
        next.contentTopInset = Double(titleInset)
        next.backingScale = Double(window.backingScaleFactor)
        next.displayID = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        next.mode = view.mode
        next.items = view.items.map { item in
            var shifted = item
            shifted.rect.y += Double(titleInset)
            return shifted
        }
        next.mouseDownCount = view.counters.mouse
        next.scrollCount = view.counters.scroll
        next.keyDownCount = view.counters.key
        next.buttonPressCount = buttonPresses
        next.resignActiveCount = resignCount
        next.isActive = NSApp.isActive
        next.sequence = manifest.sequence
        if onlyIfChanged {
            var probe = manifest
            probe.sequence = next.sequence
            if encode(probe) == encode(next) { return }
        }
        next.sequence += 1
        manifest = next
        guard let data = encode(next) else { return }
        try? data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
    }

    func encode(_ value: FixtureManifest) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}

@main
struct PublicFixtureMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate(arguments: Array(CommandLine.arguments.dropFirst()))
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

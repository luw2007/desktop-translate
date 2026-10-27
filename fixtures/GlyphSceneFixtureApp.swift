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
// Build: fixtures/build-glyph-fixture.sh. Sources: GlyphSceneManifest.swift (schema + pure geometry),
// this file (arguments, scene table, entrypoint), GlyphSceneFixtureDrawing.swift (CTLine + alpha oracle + view),
// GlyphSceneFixtureDelegate.swift (window, phase timer, watchdog, manifest publish).
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

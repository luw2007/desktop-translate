import Carbon.HIToolbox
import Foundation

@MainActor
final class FakeBackend: HotkeyBackend {
    var live: Set<Int> = []
    var occupied: Set<Shortcut> = []
    private var next = 0
    private(set) var registered: [Int: Shortcut] = [:]

    func register(_ shortcut: Shortcut) -> Result<Int, ShortcutError> {
        if occupied.contains(shortcut) { return .failure(ShortcutError("occupied")) }
        next += 1
        live.insert(next)
        registered[next] = shortcut
        return .success(next)
    }

    func unregister(_ handle: Int) { live.remove(handle) }
    var liveShortcuts: [Shortcut] { live.sorted().compactMap { registered[$0] } }
}

@main
struct ShortcutChecks {
    @MainActor
    static func main() throws {
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        func parse(_ json: String) -> Result<Shortcut, ShortcutError> {
            do { return .success(try Shortcut.parse(Data(json.utf8))) } catch { return .failure(error as! ShortcutError) }
        }
        func rejects(_ json: String, _ message: String) {
            if case .success = parse(json) { preconditionFailure("Must reject: \(message)") }
        }

        rejects("", "empty")
        rejects("[]", "array root")
        rejects(#"{"shortcut":{"keyCode":17,"modifiers":["shift"]}}"#, "shift only")
        rejects(#"{"shortcut":{"keyCode":17,"modifiers":[]}}"#, "no modifiers")
        rejects(#"{"shortcut":{"keyCode":53,"modifiers":["control"]}}"#, "escape reserved")
        rejects(#"{"shortcut":{"keyCode":55,"modifiers":["control"]}}"#, "modifier key code")
        rejects(#"{"shortcut":{"keyCode":17.5,"modifiers":["control"]}}"#, "fractional keyCode")
        rejects(#"{"shortcut":{"keyCode":true,"modifiers":["control"]}}"#, "boolean keyCode")
        rejects(#"{"shortcut":{"keyCode":"17","modifiers":["control"]}}"#, "string keyCode")
        rejects(#"{"shortcut":{"keyCode":-1,"modifiers":["control"]}}"#, "negative keyCode")
        rejects(#"{"shortcut":{"keyCode":99999,"modifiers":["control"]}}"#, "huge keyCode")
        rejects(#"{"shortcut":{"keyCode":17,"modifiers":["control","control"]}}"#, "duplicate modifier")
        rejects(#"{"shortcut":{"keyCode":17,"modifiers":["ctrl"]}}"#, "unknown modifier")
        rejects(#"{"shortcut":{"keyCode":17,"modifiers":[1]}}"#, "non-string modifier")
        rejects(#"{"shortcut":{"keyCode":17}}"#, "missing modifiers")
        rejects(#"{"shortcut":{"modifiers":["control"]}}"#, "missing keyCode")
        rejects(#"{"shortcut":{"keyCode":17,"modifiers":["control"],"extra":1}}"#, "unknown nested field")
        rejects(#"{"shortcut":{"keyCode":17,"modifiers":["control"]},"other":1}"#, "unknown top-level field")
        rejects(#"{}"#, "missing shortcut")

        // Encode/decode round trip.
        let custom = try Shortcut(keyCode: kVK_ANSI_J, modifiers: [.control, .option, .command])
        expect(try Shortcut.parse(custom.encoded()) == custom, "Round trip")

        // Store: invalid file reports an error; saved configuration reloads.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-shortcut-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShortcutStore(url: dir.appendingPathComponent("cmux-translate/config.json"))
        try store.save(custom)
        expect(try store.load() == custom, "Saved config reloads")
        try Data("{ nope".utf8).write(to: store.url)
        do { _ = try store.load(); preconditionFailure("Corrupt config must throw") } catch let error as ShortcutError {
            expect(error.message.contains(store.url.path), "Error names the file")
        }

        // Transaction invariants.
        let other = try Shortcut(keyCode: kVK_ANSI_K, modifiers: [.control, .option])
        var persisted: [Shortcut] = []
        var failPersist = false
        let backend = FakeBackend()
        let binder = try ShortcutBinder(backend: backend, initial: custom) { value in
            if failPersist { throw ShortcutError("disk full") }
            persisted.append(value)
        }

        backend.occupied = [other]
        do { try binder.apply(other); preconditionFailure("Collision must throw") } catch is ShortcutError {}
        expect(binder.current == custom && backend.liveShortcuts == [custom] && persisted.isEmpty, "Collision changes nothing")

        backend.occupied = []
        failPersist = true
        do { try binder.apply(other); preconditionFailure("Persist failure must throw") } catch {}
        expect(binder.current == custom && backend.liveShortcuts == [custom] && persisted.isEmpty, "Persist failure rolls back candidate")

        failPersist = false
        try binder.apply(other)
        expect(binder.current == other && backend.liveShortcuts == [other] && persisted == [other], "Success swaps registration and persists once")

        try binder.apply(other)
        expect(backend.liveShortcuts == [other], "Re-applying current key keeps a single registration")
        binder.shutdown()
        expect(backend.live.isEmpty, "Shutdown releases registration")

        backend.occupied = [custom]
        do { _ = try ShortcutBinder(backend: backend, initial: custom) { _ in }; preconditionFailure("Initial collision must throw") } catch {}

        print("Shortcut checks passed")
    }
}

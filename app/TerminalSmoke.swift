import AppKit
import Darwin
import Foundation

/// `--terminal-fixture-smoke` / `--terminal-fixture-pi-smoke`: ONE real session (plugin route -> OCR fallback ->
/// translation -> overlay -> hotkey dismissal) over a PUBLIC terminal fixture window, consuming the launcher handoff
/// (`fixtures/terminal_fixture_launcher.py handoff`, schema terminal-fixture-handoff/1). The launcher never declares the
/// candidate verified; every proof is re-established here against live OS facts. Output = app/version/token/counts/geometry
/// numbers only (no OCR text, titles, keys or hashes). Nothing is activated, typed, spawned or signalled by this command;
/// cleanup of a launched fixture stays with the launcher (`cleanup` never signals attached processes).
struct TerminalSmokeError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { "终端 fixture 冒烟拒绝：\(reason)（无回退，未捕获任何其他窗口）" }
}

struct TerminalFixtureHandoff: Decodable {
    struct Proc: Decodable { var pid: Int32?; var lstart: String?; var executable: String?; var alive: Bool?; var pgid: Int?; var tty: String? }
    struct Processes: Decodable { var owner: Proc; var producer: Proc }
    struct Binding: Decodable { var ownerPid: Int32; var expectedTitle: String; var claimedWindowId: Int?; var ownershipProof: String? }
    var schema: String
    var token: String
    var app: String
    var bundleId: String
    var origin: String
    var candidateStatus: String
    var ready: Bool
    var notReadyReasons: [String]
    var process: Processes
    var windowBinding: Binding
    var reportPath: String
    var stateDir: String
    var fixtureOnly: Bool
    var dailyAppsTouched: Bool
}

/// The producer's atomic JSON report (public counters only).
struct TerminalFixtureReport: Decodable {
    var token: String
    var pid: Int32
    var state: String
    var tty: String?
    var scene: String?
    var scenarioMode: String?
    var revision: Int?
    var sceneIndex: Int?
    var sceneChanges: Int?
    var renderCount: Int?
    var focusIn: Int?
    var focusOut: Int?
    var discardedInputBytes: Int?
    var cols: Int?
    var rows: Int?
    var xpixel: Int?
    var ypixel: Int?
    var updatedAtEpoch: Double?

    var json: [String: Any] {
        var o: [String: Any] = [:]
        func put(_ k: String, _ v: Int?) { if let v { o[k] = v } }
        if let scene { o["scene"] = scene }
        if let scenarioMode { o["scenarioMode"] = scenarioMode }
        put("revision", revision); put("sceneIndex", sceneIndex); put("sceneChanges", sceneChanges); put("renderCount", renderCount)
        put("focusIn", focusIn); put("focusOut", focusOut); put("discardedInputBytes", discardedInputBytes)
        put("cols", cols); put("rows", rows); put("xpixel", xpixel); put("ypixel", ypixel)
        return o
    }
}

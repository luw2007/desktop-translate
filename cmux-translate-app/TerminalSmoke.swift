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

@MainActor
struct TerminalFixtureProof {
    static let tokenEnv = "DESKTOP_TRANSLATE_TERMINAL_TOKEN"
    static let handoffEnv = "DESKTOP_TRANSLATE_TERMINAL_HANDOFF"
    static let stateRootEnv = "DESKTOP_TRANSLATE_TERMINAL_STATE_ROOT"
    static let authEnv = "DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED"
    static let reportFreshSeconds = 5.0

    let handoff: TerminalFixtureHandoff
    let reportURL: URL
    let stateURL: URL

    /// Parse + cross-check the handoff against the launcher's own state.json and the explicit token/authorization.
    static func load(environment env: [String: String]) throws -> TerminalFixtureProof {
        guard let token = env[tokenEnv], token.range(of: "^[A-Za-z0-9-]{1,48}$", options: .regularExpression) != nil else {
            throw TerminalSmokeError("缺少或非法的 token（\(tokenEnv)）")
        }
        guard env[authEnv] == token else { throw TerminalSmokeError("未获显式授权：\(authEnv) 必须等于 token") }
        guard let handoffPath = env[handoffEnv], let rootPath = env[stateRootEnv] else { throw TerminalSmokeError("缺少 handoff 文件或状态根目录") }
        let data = try readBounded(handoffPath, limit: 200_000)
        let handoff: TerminalFixtureHandoff
        do { handoff = try JSONDecoder().decode(TerminalFixtureHandoff.self, from: data) } catch { throw TerminalSmokeError("handoff 无法解析") }
        guard handoff.schema == "terminal-fixture-handoff/1", handoff.token == token else { throw TerminalSmokeError("handoff schema 或 token 不匹配") }
        guard handoff.fixtureOnly, !handoff.dailyAppsTouched else { throw TerminalSmokeError("handoff 未声明仅限 fixture") }
        let knownReasons: Set<String> = ["owner-process-not-verified-alive", "producer-not-verified-alive", "report-identity-mismatch", "report-not-running", "report-stale"]
        guard handoff.ready, handoff.notReadyReasons.isEmpty else {
            throw TerminalSmokeError("handoff 未就绪：\(handoff.notReadyReasons.filter(knownReasons.contains).joined(separator: ","))")
        }
        guard handoff.candidateStatus == "unverified", handoff.origin == "launched" || handoff.origin == "attached" else { throw TerminalSmokeError("handoff 来源或候选状态非法") }
        guard TerminalPluginRegistry.supportedTerminalNames[handoff.bundleId] != nil else { throw TerminalSmokeError("bundle 不在内置终端白名单") }
        guard let proof = handoff.windowBinding.ownershipProof, !proof.isEmpty else { throw TerminalSmokeError("缺少所有权证明记录") }
        let stateDir = URL(fileURLWithPath: rootPath).appendingPathComponent(token).standardizedFileURL
        guard URL(fileURLWithPath: handoff.stateDir).standardizedFileURL.path == stateDir.path,
              URL(fileURLWithPath: handoff.reportPath).standardizedFileURL.path == stateDir.appendingPathComponent("report.json").path else {
            throw TerminalSmokeError("handoff 路径不在预期的 fixture 状态目录内")
        }
        for p in [URL(fileURLWithPath: rootPath).standardizedFileURL.path, stateDir.path, stateDir.appendingPathComponent("report.json").path, stateDir.appendingPathComponent("state.json").path]
        where (try? FileManager.default.attributesOfItem(atPath: p))?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw TerminalSmokeError("拒绝符号链接路径")
        }
        // handoff is derived data: the launcher's persisted ownership record must say the same thing.
        guard let state = (try? JSONSerialization.jsonObject(with: readBounded(stateDir.appendingPathComponent("state.json").path, limit: 100_000))) as? [String: Any],
              state["token"] as? String == token, state["bundleId"] as? String == handoff.bundleId,
              (state["emulatorPid"] as? NSNumber)?.int32Value == handoff.process.owner.pid,
              (state["producerPid"] as? NSNumber)?.int32Value == handoff.process.producer.pid,
              state["emulatorLstart"] as? String == handoff.process.owner.lstart,
              state["producerLstart"] as? String == handoff.process.producer.lstart,
              (handoff.origin == "attached") == ((state["attached"] as? Bool) == true),
              handoff.windowBinding.ownerPid == handoff.process.owner.pid,
              handoff.windowBinding.expectedTitle == "DT-Fixture-" + token else {
            throw TerminalSmokeError("handoff 与 launcher 状态记录不一致")
        }
        // Dedicated-process proof. Descendant/single-window/title never prove the owner process holds no daily tabs or panes.
        if handoff.origin == "launched" {
            guard (state["ownershipProof"] as? String)?.hasPrefix("spawned-by-launcher") == true,
                  (state["attached"] as? Bool) != true else { throw TerminalSmokeError("launched 状态缺少 launcher 自行拉起的证明") }
        } else {
            // Attached: refuse unless the launcher state carries an explicit attestation that the owner is a NEW disposable
            // fixture-only process (not the daily app instance) and the window id is claimed; a boolean/token alone is not trusted.
            guard state["fixtureAttestation"] as? String == "new-disposable-process-fixture-only",
                  state["dailyInstanceReused"] as? Bool == false,
                  (state["claimedWindowId"] as? NSNumber) != nil,
                  handoff.windowBinding.claimedWindowId != nil else {
                throw TerminalSmokeError("attach 缺少“全新一次性 fixture 进程、非日常实例”的显式声明与 windowID；拒绝信任")
            }
            // Machine recheck: immutable plan predates the live owner's start; claimed window id is identical in handoff and state.
            guard let planData = try? readBounded(stateDir.appendingPathComponent("attach-plan.json").path, limit: 20_000),
                  let plan = (try? JSONSerialization.jsonObject(with: planData)) as? [String: Any],
                  plan["token"] as? String == token,
                  let planEpoch = (plan["planCreatedAtEpoch"] as? NSNumber)?.doubleValue,
                  (state["planCreatedAtEpoch"] as? NSNumber)?.doubleValue == planEpoch,
                  (state["claimedWindowId"] as? NSNumber)?.intValue == handoff.windowBinding.claimedWindowId,
                  let ownerPID = handoff.process.owner.pid, let ownerFacts = facts(ownerPID),
                  Double(ownerFacts.startSeconds) > planEpoch,
                  let recordedStart = (state["ownerStartEpoch"] as? NSNumber)?.doubleValue,
                  abs(recordedStart - Double(ownerFacts.startSeconds)) <= 1.0,
                  (state["planCreatedMonotonic"] as? NSNumber) != nil,
                  (state["attestationKind"] as? String)?.contains("operator") == true else {
                throw TerminalSmokeError("attach 的 owner 启动时间不晚于不可变 attach-plan，或计划记录不一致；拒绝信任")
            }
        }
        return TerminalFixtureProof(handoff: handoff, reportURL: stateDir.appendingPathComponent("report.json"), stateURL: stateDir)
    }

    private static func readBounded(_ path: String, limit: Int) throws -> Data {
        guard let data = FileManager.default.contents(atPath: path), data.count <= limit else { throw TerminalSmokeError("文件缺失或过大") }
        return data
    }

    private struct Facts { var ppid: Int32; var startSeconds: Int; var ttyDev: Int32 }
    private static func facts(_ pid: Int32) -> Facts? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return Facts(ppid: info.kp_eproc.e_ppid, startSeconds: Int(info.kp_proc.p_un.__p_starttime.tv_sec), ttyDev: info.kp_eproc.e_tdev)
    }
    /// Parses a launcher-recorded `ps -o lstart=` string (local time) with exactly the two documented layouts
    /// (day-before-month is the real macOS form; month-first is accepted), and returns whole epoch seconds.
    private static func lstartEpoch(_ text: String?) -> Int? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["EEE d MMM HH:mm:ss yyyy", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return Int(date.timeIntervalSince1970.rounded()) }
        }
        return nil
    }
    private static func sameStart(_ f: Facts, _ recorded: String?) -> Bool { lstartEpoch(recorded) == f.startSeconds }

    func readReport() throws -> TerminalFixtureReport {
        guard let data = FileManager.default.contents(atPath: reportURL.path), data.count <= 100_000,
              let report = try? JSONDecoder().decode(TerminalFixtureReport.self, from: data) else { throw TerminalSmokeError("producer 报告缺失或无法解析") }
        guard report.token == handoff.token, report.pid == handoff.process.producer.pid, report.state == "running" else { throw TerminalSmokeError("producer 报告身份或状态不匹配") }
        guard let updated = report.updatedAtEpoch, Date().timeIntervalSince1970 - updated <= Self.reportFreshSeconds else { throw TerminalSmokeError("producer 报告已过期") }
        guard report.tty == handoff.process.producer.tty, let tty = report.tty, tty.hasPrefix("/dev/ttys") else { throw TerminalSmokeError("producer tty 记录不匹配") }
        return report
    }

    /// Live re-verification of owner/producer: start identity, ancestry and controlling tty. Called before AND after the run.
    func verifyProcesses() throws -> NSRunningApplication {
        let owner = handoff.process.owner, producer = handoff.process.producer
        guard let ownerPID = owner.pid, let producerPID = producer.pid, ownerPID > 1, producerPID > 1,
              ownerPID != ProcessInfo.processInfo.processIdentifier else { throw TerminalSmokeError("handoff 进程 ID 非法") }
        guard let ownerFacts = Self.facts(ownerPID), Self.sameStart(ownerFacts, owner.lstart) else { throw TerminalSmokeError("owner 进程不存在或启动标识不符") }
        guard let producerFacts = Self.facts(producerPID), Self.sameStart(producerFacts, producer.lstart) else { throw TerminalSmokeError("producer 进程不存在或启动标识不符") }
        var cursor = producerFacts.ppid, hops = 0, descends = false
        while cursor > 1, hops < 16 {
            if cursor == ownerPID { descends = true; break }
            guard let next = Self.facts(cursor) else { break }
            cursor = next.ppid; hops += 1
        }
        guard descends else { throw TerminalSmokeError("producer 不是 owner 进程的后代，所有权未证明") }
        guard let tty = producer.tty, tty.hasPrefix("/dev/ttys") else { throw TerminalSmokeError("缺少 producer tty") }
        var st = stat()
        guard stat(tty, &st) == 0, st.st_rdev != 0, producerFacts.ttyDev == Int32(truncatingIfNeeded: st.st_rdev) else { throw TerminalSmokeError("producer 控制终端与报告的 tty 不一致") }
        guard let app = NSRunningApplication(processIdentifier: ownerPID), !app.isTerminated,
              app.bundleIdentifier == handoff.bundleId, app.processIdentifier == ownerPID else { throw TerminalSmokeError("owner 进程不是预期 bundle 的应用") }
        return app
    }

    /// The locked product target must be exactly the handed-off owner's single ordinary window; no equal-frame or
    /// root exceptions. A non-empty title must carry the fixture marker; the claimed window id (if any) must be exact.
    func verifyWindow(_ target: CaptureTarget) throws {
        guard target.pid == handoff.process.owner.pid, target.bundleID == handoff.bundleId else { throw TerminalSmokeError("锁定目标不属于 handoff owner") }
        guard TargetLocker.ordinaryWindowIDs(pid: target.pid) == [target.windowID] else { throw TerminalSmokeError("owner 进程不止一个普通窗口，窗口归属有歧义") }
        if let claimed = handoff.windowBinding.claimedWindowId, UInt32(exactly: claimed) != target.windowID { throw TerminalSmokeError("锁定窗口与声明的 windowID 不一致") }
        let titled = target.title.contains(handoff.windowBinding.expectedTitle)
        if !target.title.isEmpty && !titled { throw TerminalSmokeError("窗口标题不含 fixture 标记") }
        guard titled || handoff.windowBinding.claimedWindowId != nil else { throw TerminalSmokeError("窗口标题不可读且没有声明的 windowID，无法证明窗口归属") }
    }
}

extension AppDelegate {
    private func terminalLevels(_ c: SnapshotCapabilities) -> [String: String] {
        ["visibleText": c.visibleText.effectiveLevel.rawValue, "textGeometry": c.textGeometry.effectiveLevel.rawValue,
         "paneLayout": c.paneLayout.effectiveLevel.rawValue, "contentRevision": c.contentRevision.effectiveLevel.rawValue,
         "fontRevision": c.fontRevision.effectiveLevel.rawValue]
    }

    /// ONE real session over the handed-off public terminal fixture. Refuses (no fallback) on any identity, ownership,
    /// readiness or window mismatch. Never activates, types, spawns or signals; the selected backend is kept (`--pi`
    /// variant overrides to pi explicitly, like glyph-pi-smoke).
    func runTerminalFixtureSmoke() async {
        loadSelectedSettings()
        if mode == .terminalFixturePiSmoke {
            currentSettings.mode = .pi
            if let model = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_PI_MODEL"] { currentSettings.model = model }
            if let executable = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_PI_EXECUTABLE"] { currentSettings.piExecutable = executable }
        }
        var result: [String: Any] = ["backend": currentSettings.mode.rawValue, "workflow": "terminal-fixture-smoke"]
        let proof: TerminalFixtureProof
        let app: NSRunningApplication
        do {
            proof = try TerminalFixtureProof.load(environment: ProcessInfo.processInfo.environment)
            app = try proof.verifyProcesses()
        } catch { smokeFail(error.localizedDescription, result) }
        result["token"] = proof.handoff.token
        result["app"] = TerminalPluginRegistry.supportedTerminalNames[proof.handoff.bundleId] ?? "unknown"
        result["bundleID"] = proof.handoff.bundleId
        result["origin"] = proof.handoff.origin
        result["appVersion"] = (app.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        result["ownerPID"] = Int(app.processIdentifier)
        let before: TerminalFixtureReport
        do { before = try proof.readReport() } catch { smokeFail(error.localizedDescription, result) }

        // Owned-window readiness without any activation: exactly one ordinary window of the owner pid, stable on two
        // ticks, and the owner naturally frontmost on two ticks. The window is then re-bound through the product lock.
        let deadline = Date().addingTimeInterval(10)
        var stable = 0, last: CaptureTarget?
        while stable < 2 {
            guard !app.isTerminated else { smokeFail("owner 应用在就绪前退出。", result) }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
               case .success(let t) = TargetLocker.lock(app: app),
               TargetLocker.ordinaryWindowIDs(pid: t.pid) == [t.windowID] {
                stable = (last.map { $0.windowID == t.windowID && $0.frame == t.frame } ?? false) ? stable + 1 : 1
                last = t
            } else { stable = 0; last = nil }
            if stable >= 2 { break }
            guard Date() < deadline else { smokeFail("owner 窗口未在期限内自然成为前台的唯一普通窗口（不会激活或切换）。", result) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let locked: CaptureTarget
        do {
            guard let candidate = last else { throw TerminalSmokeError("没有可锁定的窗口") }
            try proof.verifyWindow(candidate)
            locked = candidate
        } catch { smokeFail(error.localizedDescription, result) }
        result["windowID"] = Int(locked.windowID)
        result["windowSize"] = ["width": locked.frame.width, "height": locked.frame.height]
        result["displays"] = locked.displayIDs.count
        result["builtinPlugin"] = TerminalPluginRegistry().hasPlugin(for: locked)

        do { try installHotkey(initial: .defaultShortcut) } catch { smokeFail("无法注册默认快捷键。", result) }
        let started = Date()
        let session = startSession(run: .fullWindow, frontmost: app)
        let presented = await settle(timeout: 300) { session.phaseDescription == "presenting" || session.phaseDescription == "failed" || session.isFinished }
        result["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        result["phase"] = session.phaseDescription
        guard presented, session.phaseDescription == "presenting", let snapshot = session.presentedSnapshot, let sessionTarget = session.target else {
            // Raw HUD status can carry backend/pi/provider text; report only the fixed class and the session phase.
            let phase = session.phaseDescription
            session.dismiss(reason: nil)
            result["failureClass"] = presented ? "session-not-presenting" : "session-timeout"
            result["failurePhase"] = phase
            smokeFail("翻译未进入展示阶段（详情不转发，见阶段码）。", result)
        }
        var checks: [String: Bool] = [:]
        checks["sessionTargetIsBoundWindow"] = sessionTarget.sameWindow(as: locked) && (try? proof.verifyWindow(sessionTarget)) != nil
        checks["snapshotTargetIsBoundWindow"] = snapshot.target.sameWindow(as: locked)

        // Surface source/support/association; geometry accuracy is deliberately NOT measured (no oracle).
        result["source"] = ["label": session.hudSourceText, "snapshotProvenance": snapshot.provenance.rawValue,
                            "capabilities": terminalLevels(snapshot.capabilities)]
        if let source = pluginRegistry.currentCaptureSource {
            result["pluginSource"] = ["interface": source.evidence.interface, "applicationVersion": source.evidence.applicationVersion,
                                      "versionVerified": source.evidence.versionVerified,
                                      "provenance": source.provenance?.rawValue ?? "none",
                                      "evidence": ["visibleText": source.evidence.visibleText.rawValue, "textGeometry": source.evidence.textGeometry.rawValue,
                                                   "paneLayout": source.evidence.paneLayout.rawValue, "contentRevision": source.evidence.contentRevision.rawValue,
                                                   "fontRevision": source.evidence.fontRevision.rawValue]]
        } else { result["pluginSource"] = NSNull() }
        var lineMismatch = 0, maskItems = 0, maskLines = 0, maskBroken = 0, collisions = 0, overflows = 0
        for region in snapshot.regions {
            let lines = region.text.components(separatedBy: "\n").count
            if lines != (region.lineRects.isEmpty ? 1 : region.lineRects.count) { lineMismatch += 1 }
        }
        for item in session.presentedItems {
            if item.overflow { overflows += 1 }
            if item.occupancyUnavailable { collisions += 1; continue }
            maskItems += 1
            guard let region = snapshot.regions.first(where: { $0.id == item.regionID }) else { maskBroken += 1; continue }
            let expected = region.lineRects.isEmpty ? 1 : region.lineRects.count
            if expected != item.occupied.count || region.text.components(separatedBy: "\n").count != expected { maskBroken += 1 } else { maskLines += expected }
        }
        result["counts"] = ["regions": snapshot.regions.count, "layoutRegions": snapshot.layout.count, "overlayItems": session.presentedItems.count,
                            "ocrLineMismatchRegions": lineMismatch, "maskItems": maskItems, "maskLines": maskLines, "maskAssociationBroken": maskBroken,
                            "occupancyUnavailableItems": collisions, "overflowItems": overflows]
        result["geometry"] = ["measured": false, "note": "no oracle for terminal glyph geometry; source/support/association only"]
        checks["maskAssociated"] = maskBroken == 0 && maskItems > 0
        checks["hasChinese"] = session.presentedItems.contains { $0.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        checks["minimumFontSize"] = session.presentedItems.allSatisfy { $0.fontSize >= OverlayItem.minimumFontSize }
        checks["targetStayedFrontmost"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier && !NSApp.isActive

        // Real PTY counters (producer-reported): disclosed deltas; synthetic CSI is never physical-input evidence.
        let after = try? proof.readReport()
        if let after {
            func delta(_ a: Int?, _ b: Int?) -> Int? { (a != nil && b != nil) ? b! - a! : nil }
            var counters: [String: Any] = ["before": before.json, "after": after.json]
            for (name, a, b) in [("focusIn", before.focusIn, after.focusIn), ("focusOut", before.focusOut, after.focusOut),
                                 ("discardedInputBytes", before.discardedInputBytes, after.discardedInputBytes),
                                 ("revision", before.revision, after.revision), ("renderCount", before.renderCount, after.renderCount),
                                 ("sceneChanges", before.sceneChanges, after.sceneChanges)] {
                if let d = delta(a, b) { counters[name + "Delta"] = d }
            }
            result["producerCounters"] = counters
            checks["fixtureReceivedNoInput"] = delta(before.discardedInputBytes, after.discardedInputBytes) == 0
            checks["sceneStableDuringCapture"] = delta(before.sceneChanges, after.sceneChanges) == 0
        } else { checks["fixtureReceivedNoInput"] = false; checks["sceneStableDuringCapture"] = false }
        checks["ownershipStillProven"] = (try? proof.verifyProcesses()) != nil

        postSyntheticHotkey()
        checks["hotkeyDismisses"] = await settle { self.session == nil } && session.isFinished && !(session.barrierPanel?.isVisible ?? false)
        binder?.shutdown(); backend?.shutdown(); binder = nil; backend = nil
        result["checks"] = checks
        // The fixture and its processes are NOT touched here; launcher `cleanup --token` owns spawned-only cleanup.
        let failed = checks.filter { !$0.value }.keys.sorted()
        if !failed.isEmpty { result["failedChecks"] = failed; smokeFail("terminal fixture 冒烟断言失败。", result) }
        result["ok"] = true
        emit(result)
        exit(0)
    }
}

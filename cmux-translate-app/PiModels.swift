import Foundation

/// One entry of pi's `get_available_models` snapshot. Only the fields this app needs are kept: no headers,
/// base URLs, costs or other provider configuration ever leave the decoder.
struct PiModel: Equatable, Sendable {
    let provider: String
    let id: String
    let name: String
    /// True only when pi's own `input` metadata contains "image". Never inferred from a brand or a name.
    let acceptsImages: Bool

    /// Value stored in `TranslationSettings.model` (pi's `provider/id`; ids may contain further slashes).
    var identifier: String { "\(provider)/\(id)" }
}

/// Pure decoding of pi RPC JSONL. No response text is ever interpolated into an error.
enum PiRPCProtocol {
    struct CommandResponse {
        let success: Bool
        let data: [String: Any]?
    }

    static func command(_ id: String, _ type: String, _ fields: [String: Any] = [:]) -> Data {
        var object = fields
        object["id"] = id
        object["type"] = type
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// LF-only framing, like pi's own reader (U+2028/2029 are legal inside JSON strings).
    static func lines(_ wire: Data) -> [Data] {
        wire.split(separator: 0x0A, omittingEmptySubsequences: true).map { slice in
            var line = Data(slice)
            if line.last == 0x0D { line.removeLast() }
            return line
        }.filter { !$0.allSatisfy { [0x20, 0x09].contains($0) } }
    }

    static func record(_ line: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["type"] is String else {
            throw PiTranslationError("pi 返回了无效的 JSON 事件。")
        }
        return object
    }

    /// Every command response in the stream, by request id. A repeated id is a protocol violation.
    static func responses(stdout: Data) throws -> [String: CommandResponse] {
        var result: [String: CommandResponse] = [:]
        for line in lines(stdout) {
            let object = try record(line)
            guard object["type"] as? String == "response" else { continue }
            guard let id = object["id"] as? String, let success = object["success"] as? Bool else {
                throw PiTranslationError("pi 返回了无效的命令响应。")
            }
            guard result[id] == nil else { throw PiTranslationError("pi 返回了重复的命令响应。") }
            result[id] = CommandResponse(success: success, data: object["data"] as? [String: Any])
        }
        return result
    }

    /// `get_available_models` payload → bounded, validated model list (sorted, unique provider/id).
    /// Entries that cannot be selected safely (empty/whitespace/control/option-like identity) are dropped, never repaired.
    static func models(from data: [String: Any]?) throws -> [PiModel] {
        guard let raw = data?["models"] as? [Any], raw.count <= 5_000 else { throw PiTranslationError("pi 返回了无效的模型列表。") }
        var seen = Set<String>()
        var models: [PiModel] = []
        for entry in raw {
            guard let object = entry as? [String: Any], let provider = object["provider"] as? String, let id = object["id"] as? String,
                  !provider.isEmpty, !id.isEmpty, !provider.contains("/") else { continue }
            let model = PiModel(provider: provider, id: id, name: (object["name"] as? String) ?? id,
                                acceptsImages: ((object["input"] as? [Any]) ?? []).contains { ($0 as? String) == "image" })
            guard (try? TranslationSettings.validateModel(model.identifier)) != nil, seen.insert(model.identifier).inserted else { continue }
            models.append(model)
        }
        return models.sorted { ($0.provider, $0.id) < ($1.provider, $1.id) }
    }
}

/// Interactive RPC conversation driven by pi's own stdout. Called serially from the spawner's I/O thread; read the
/// outcome only after the process has been reaped.
///
/// discover : get_available_models, then EOF. No model request is made.
/// translate: get_available_models → the selected provider/id must exist AND declare image input (otherwise nothing
///            is written and EOF is sent: the screenshot never reaches a model) → set_model → prompt with one
///            in-memory base64 PNG → EOF only once `agent_settled` arrives. The prompt command response is merely
///            an acceptance acknowledgement, never completion.
final class PiRPCDriver: DisclaimInteractiveDriver, @unchecked Sendable {
    typealias Step = DisclaimInteractiveStep
    enum Job {
        case discover
        case translate(provider: String, modelID: String, message: String, imagePNGBase64: String)
    }
    enum Refusal: Equatable { case modelUnavailable, modelLacksImageInput, commandFailed }

    static let modelsID = "models", setID = "set", promptID = "prompt"

    let job: Job
    private(set) var refusal: Refusal?
    private var pending = Data()
    private var promptCommand: Data?

    init(job: Job) { self.job = job }

    var initialInput: Data { PiRPCProtocol.command(Self.modelsID, "get_available_models") }

    func consume(_ chunk: Data) -> Step {
        pending.append(chunk)
        var step = Step()
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            let next = handle(line)
            step.write.append(next.write)
            step.closeInput = step.closeInput || next.closeInput
        }
        return step
    }

    private func handle(_ line: Data) -> Step {
        guard let object = try? PiRPCProtocol.record(line), let type = object["type"] as? String else { return Step() }
        if type == "agent_settled" { return Step(write: Data(), closeInput: true) }
        guard type == "response", let id = object["id"] as? String else { return Step() }
        guard object["success"] as? Bool == true else {
            refusal = refusal ?? .commandFailed
            return Step(write: Data(), closeInput: true)
        }
        switch (id, job) {
        case (Self.modelsID, .discover):
            return Step(write: Data(), closeInput: true)
        case (Self.modelsID, .translate(let provider, let modelID, let message, let image)):
            guard let models = try? PiRPCProtocol.models(from: object["data"] as? [String: Any]),
                  let model = models.first(where: { $0.provider == provider && $0.id == modelID }) else {
                refusal = .modelUnavailable
                return Step(write: Data(), closeInput: true)
            }
            guard model.acceptsImages else {
                refusal = .modelLacksImageInput
                return Step(write: Data(), closeInput: true)
            }
            promptCommand = PiRPCProtocol.command(Self.promptID, "prompt", [
                "message": message,
                "images": [["type": "image", "data": image, "mimeType": "image/png"]],
            ])
            return Step(write: PiRPCProtocol.command(Self.setID, "set_model", ["provider": provider, "modelId": modelID]), closeInput: false)
        case (Self.setID, .translate):
            defer { promptCommand = nil }
            return Step(write: promptCommand ?? Data(), closeInput: promptCommand == nil)
        default:
            return Step()
        }
    }

    func failure() -> PiTranslationError? {
        switch refusal {
        case .modelUnavailable?: return PiTranslationError("所选模型不在 pi 当前可用模型中；截图未发送。请在翻译设置中重新选择。")
        case .modelLacksImageInput?: return PiTranslationError("所选模型不接受图像输入；截图未发送。请在翻译设置中选择支持图像的模型。")
        case .commandFailed?: return PiTranslationError("pi 拒绝了命令（模型认证或可用性问题）；请检查 pi 配置。")
        case nil: return nil
        }
    }
}

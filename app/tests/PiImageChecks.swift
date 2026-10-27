import CoreGraphics
import Foundation

/// Behavioural boundaries of the pi image path: RPC conversation ordering and refusal, available-model decoding,
/// and strict region/geometry validation. No process, no network, no model.
@main
struct PiImageChecks {
    static let secret = "PRIVATE_MODEL_TEXT_MARKER"
    static func expect(_ c: Bool, _ m: String) { precondition(c, m) }

    static func models(_ entries: [[String: Any]]) -> [String: Any] { ["models": entries] }
    static func model(_ provider: String, _ id: String, input: [String]) -> [String: Any] {
        ["provider": provider, "id": id, "name": "n", "input": input, "headers": ["Authorization": secret], "baseUrl": "https://x"]
    }
    static func line(_ object: [String: Any]) -> Data {
        var d = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); d.append(0x0A); return d
    }
    static func response(_ id: String, _ command: String, data: Any? = nil, success: Bool = true) -> Data {
        var o: [String: Any] = ["type": "response", "id": id, "command": command, "success": success]
        if let data { o["data"] = data }
        return line(o)
    }
    static func commands(_ data: Data) -> [[String: Any]] {
        PiRPCProtocol.lines(data).map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] }
    }

    static func main() {
        // --- available models: only provider/id/name/image capability survive; slashed ids keep identity.
        let decoded = try! PiRPCProtocol.models(from: models([
            model("router", "org/sub/vision", input: ["text", "image"]),
            model("alpha", "text-only", input: ["text"]),
            model("alpha", "text-only", input: ["text"]),                // duplicate identity dropped
            model("bad/provider", "x", input: ["text"]),                  // provider with slash is not addressable
            model("alpha", "has space", input: ["text"]),                 // not a safe single token
            ["provider": "alpha", "id": "no-input-field"],
        ]))
        expect(decoded.map(\.identifier) == ["alpha/no-input-field", "alpha/text-only", "router/org/sub/vision"], "Sorted unique selectable models")
        expect(decoded.first { $0.id == "org/sub/vision" }?.acceptsImages == true, "Image input from metadata")
        expect(decoded.first { $0.id == "text-only" }?.acceptsImages == false && decoded.first { $0.id == "no-input-field" }?.acceptsImages == false, "No image input unless declared")
        expect((try? PiRPCProtocol.models(from: ["models": "x"])) == nil && (try? PiRPCProtocol.models(from: nil)) == nil, "Malformed list rejected")

        // --- discovery: one command, EOF after its response, no model call.
        let discover = PiRPCDriver(job: .discover)
        expect(commands(discover.initialInput).map { $0["type"] as? String } == ["get_available_models"], "Discovery asks only for models")
        let done = discover.consume(response("models", "get_available_models", data: models([])))
        expect(done.closeInput && done.write.isEmpty, "Discovery ends with EOF and writes nothing")

        // --- translation ordering: models -> set_model -> prompt (with exactly one in-memory PNG) -> EOF only at settle.
        func translating() -> PiRPCDriver {
            PiRPCDriver(job: .translate(provider: "router", modelID: "org/sub/vision", message: "M", imagePNGBase64: "QUJD"))
        }
        let driver = translating()
        let list = models([model("router", "org/sub/vision", input: ["text", "image"])])
        // A chunk boundary in the middle of a line must not matter.
        let wire = response("models", "get_available_models", data: list)
        let cut = wire.count / 2
        expect(driver.consume(wire.prefix(cut)).write.isEmpty, "Partial line waits")
        let afterModels = driver.consume(wire.suffix(from: cut))
        let setCommand = commands(afterModels.write)
        expect(setCommand.count == 1 && setCommand[0]["type"] as? String == "set_model"
            && setCommand[0]["provider"] as? String == "router" && setCommand[0]["modelId"] as? String == "org/sub/vision" && !afterModels.closeInput, "set_model with provider and slashed id")
        let afterSet = driver.consume(response("set", "set_model", data: [:]))
        let prompt = commands(afterSet.write)
        let images = prompt.first?["images"] as? [[String: Any]]
        expect(prompt.count == 1 && prompt[0]["type"] as? String == "prompt" && images?.count == 1
            && images?[0]["mimeType"] as? String == "image/png" && images?[0]["data"] as? String == "QUJD" && !afterSet.closeInput, "Prompt carries one base64 PNG")
        let ack = driver.consume(response("prompt", "prompt"))
        expect(ack.write.isEmpty && !ack.closeInput, "Prompt acknowledgement is not completion")
        let assistant = driver.consume(line(["type": "message_end", "message": ["role": "assistant", "content": [], "stopReason": "stop"]]))
        expect(!assistant.closeInput, "Message end is not completion")
        expect(driver.consume(line(["type": "agent_settled", "aborted": false])).closeInput, "EOF only after agent_settled")
        expect(driver.failure() == nil, "No refusal on the happy path")

        // --- refusals send nothing to a model and close stdin.
        for (label, entries, want) in [
            ("text-only", [model("router", "org/sub/vision", input: ["text"])], "图像"),
            ("absent", [model("other", "x", input: ["text", "image"])], "不在"),
        ] as [(String, [[String: Any]], String)] {
            let d = translating()
            let step = d.consume(response("models", "get_available_models", data: models(entries)))
            expect(step.write.isEmpty && step.closeInput, "\(label): no set_model/prompt, EOF")
            expect(d.failure()?.message.contains(want) == true && d.failure()?.message.contains(secret) == false, "\(label): fixed refusal")
        }
        let failed = translating()
        let failStep = failed.consume(response("models", "get_available_models", success: false))
        expect(failStep.closeInput && failStep.write.isEmpty && failed.failure() != nil, "Failed command stops the conversation")
        let failedSet = translating()
        _ = failedSet.consume(response("models", "get_available_models", data: list))
        let failedSetStep = failedSet.consume(response("set", "set_model", success: false))
        expect(failedSetStep.closeInput && failedSetStep.write.isEmpty, "Failed set_model never prompts")

        // --- the final answer is read from the settled stream; response records never count as an answer.
        let answer = #"{"regions":[]}"#
        var stream = response("models", "get_available_models", data: list) + response("prompt", "prompt")
        stream.append(line(["type": "message_end", "message": ["role": "assistant", "content": [["type": "text", "text": answer]], "stopReason": "stop"]]))
        stream.append(line(["type": "agent_settled", "aborted": false]))
        expect((try? PiResponseParser.finalText(stdout: stream, exitStatus: 0)) == answer, "Final text from settled RPC stream")
        expect((try? PiResponseParser.finalText(stdout: response("prompt", "prompt"), exitStatus: 0)) == nil, "Acknowledgement alone is not a result")

        // --- region/geometry validation, normalized to the submitted crop.
        let crop = CGRect(x: 100, y: 50, width: 400, height: 200)
        func region(_ id: String = "r1", kind: String = "prose", translation: String = "你好", text: String = "Hello", box: [Any] = [0.1, 0.2, 0.5, 0.25]) -> [String: Any] {
            ["id": id, "kind": kind, "translation": translation, "lines": [["text": text, "box": box]]]
        }
        func wireText(_ regions: [[String: Any]]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: ["regions": regions]), encoding: .utf8)!
        }
        let ok = try! PiImageResponse.parse(wireText([region(), region("r2", kind: "label", translation: "好", text: "Ok", box: [0, 0.8, 1, 0.2])]), crop: crop)
        expect(ok.regions.map(\.id) == ["r1", "r2"] && ok.regions.map(\.readingOrder) == [0, 1], "Array order is reading order")
        let firstLine = ok.regions[0].lineRects[0]
        expect(abs(firstLine.minX - 140) < 0.0001 && abs(firstLine.minY - 90) < 0.0001
            && abs(firstLine.width - 200) < 0.0001 && abs(firstLine.height - 50) < 0.0001,
            "Fractions map into window-local crop points")
        let fullWidth = ok.regions[1].rect
        expect(abs(fullWidth.minX - 100) < 0.0001 && abs(fullWidth.minY - 210) < 0.0001
            && abs(fullWidth.width - 400) < 0.0001 && abs(fullWidth.height - 40) < 0.0001,
            "Full-width box maps to crop edges")
        expect(ok.regions[0].parentID == "selection" && ok.translations["r1"] == "你好", "Parent identity and translation")
        // Slight overshoot is clamped to the crop; real overshoot is refused.
        let clamped = try! PiImageResponse.parse(wireText([region(box: [-0.004, 0.9, 1.0, 0.104])]), crop: crop)
        expect(crop.contains(clamped.regions[0].rect), "Tolerated rounding is clamped inside the crop")

        let bad: [(String, String)] = [
            ("fenced", "```json\n" + wireText([region()]) + "\n```"),
            ("commentary", wireText([region()]) + " " + secret),
            ("empty regions", wireText([])),
            ("duplicate id", wireText([region(), region()])),
            ("empty id", wireText([region("")])),
            ("unknown kind", wireText([region(kind: "poem")])),
            ("blank translation", wireText([region(translation: "  ")])),
            ("zero width", wireText([region(box: [0.1, 0.1, 0, 0.1])])),
            ("negative height", wireText([region(box: [0.1, 0.1, 0.1, -0.1])])),
            ("outside crop", wireText([region(box: [0.8, 0.1, 0.5, 0.1])])),
            ("below crop", wireText([region(box: [0.1, 0.95, 0.1, 0.2])])),
            ("three numbers", wireText([region(box: [0.1, 0.1, 0.1])])),
            ("string number", wireText([region(box: ["0.1", 0.1, 0.1, 0.1])])),
            ("boolean number", wireText([region(box: [true, 0.1, 0.1, 0.1])])),
            ("extra field", wireText([region().merging(["extra": 1]) { a, _ in a }])),
            ("extra root field", #"{"regions":[],"x":1}"#),
        ]
        for (label, text) in bad {
            do { _ = try PiImageResponse.parse(text, crop: crop); preconditionFailure("\(label): accepted") }
            catch { expect(!String(describing: error).contains(secret) && !error.localizedDescription.contains(secret), "\(label): error leaked model text") }
        }
        expect((try? PiImageResponse.parse(wireText([region()]), crop: CGRect(x: 0, y: 0, width: 0, height: 10))) == nil, "Degenerate crop refused")
        print("PiImageChecks: all passed")
    }
}

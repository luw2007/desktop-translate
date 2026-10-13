import Foundation

@main
struct PiResponseChecks {
    static let secret = "PRIVATE_SOURCE_RESPONSE_PROVIDER_MARKER"

    static func record(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    static func stream(_ records: [[String: Any]]) -> Data {
        records.reduce(into: Data()) { $0.append(record($1)) }
    }

    static func text(_ value: String) -> [String: Any] {
        ["type": "text", "text": value]
    }

    static func end(_ blocks: [[String: Any]], reason: String = "stop", role: String = "assistant") -> [String: Any] {
        ["type": "message_end", "message": ["role": role, "content": blocks, "stopReason": reason]]
    }

    static func settled(_ aborted: Bool = false) -> [String: Any] {
        ["type": "agent_settled", "aborted": aborted]
    }

    static func response(_ output: String) -> Data {
        stream([end([text(output)]), settled()])
    }

    static func accepts(_ data: Data, ids: [String] = ["one"], expected: [String: String], label: String) {
        do {
            let actual = try PiResponseParser.parse(stdout: data, exitStatus: 0, expectedIDs: ids)
            precondition(actual == expected, label)
        } catch {
            preconditionFailure("\(label): unexpectedly rejected (error details intentionally withheld)")
        }
    }

    static func rejects(_ data: Data, status: Int32 = 0, ids: [String] = ["one"], label: String) {
        do {
            _ = try PiResponseParser.parse(stdout: data, exitStatus: status, expectedIDs: ids)
            preconditionFailure("\(label): unexpectedly accepted")
        } catch {
            let descriptions = [String(describing: error), error.localizedDescription, String(reflecting: error)]
            precondition(descriptions.allSatisfy { !$0.contains(secret) }, "\(label): error leaked private input")
        }
    }

    static func main() {
        let valid = #"{"one":"译文"}"#
        accepts(response(valid), expected: ["one": "译文"], label: "Simple completed response")
        accepts(response(" \n" + valid + "\n\t"), expected: ["one": "译文"], label: "JSON surrounding whitespace")
        accepts(response(#"{"two":"第二行","one":"第一行\n后续"}"#), ids: ["one", "two"], expected: ["one": "第一行\n后续", "two": "第二行"], label: "IDs match independent of dictionary order")

        rejects(Data(), label: "Empty stdout")
        rejects(Data("\n \t\n".utf8), label: "Whitespace-only stdout")
        rejects(response(valid), status: 1, label: "Nonzero process exit")
        rejects(response(valid), status: -9, label: "Signal-like process failure")
        rejects(stream([end([text(valid)])]), label: "Missing settled event")
        rejects(stream([settled()]), label: "Missing final assistant message")
        rejects(stream([settled(), end([text(valid)])]), label: "Settled must follow final message")
        rejects(stream([end([text(valid)]), settled(true)]), label: "Aborted settled event")
        rejects(stream([end([text(valid)]), ["type": "agent_settled"]]), label: "Missing aborted flag")
        rejects(stream([end([text(valid)]), ["type": "agent_settled", "aborted": "false"]]), label: "Aborted flag must be Boolean")
        for reason in ["error", "aborted", "length", "toolUse"] {
            rejects(stream([end([text(valid)], reason: reason), settled()]), label: "Final stop reason \(reason) is failure")
            rejects(stream([end([text(valid)]), end([text(valid)], reason: reason), settled()]), label: "Final \(reason) cannot fall back to earlier success")
        }
        rejects(stream([["type": "message_end", "message": ["role": "assistant", "content": [text(valid)], "errorMessage": secret]], settled()]), label: "Assistant error with no successful stop reason")
        rejects(stream([["type": "message_end", "message": ["role": "assistant", "content": [text(valid)]]], settled()]), label: "Missing final stop reason")
        accepts(stream([
            end([text(secret)], reason: "error"),
            ["type": "agent_end", "messages": [], "willRetry": true],
            ["type": "auto_retry_start", "attempt": 1, "maxAttempts": 3, "delayMs": 2000, "errorMessage": secret],
            end([text(valid)]),
            ["type": "auto_retry_end", "success": true, "attempt": 1],
            ["type": "agent_end", "messages": [], "willRetry": false],
            settled()
        ]), expected: ["one": "译文"], label: "Successful retry replaces earlier assistant failure")
        rejects(stream([
            end([text(valid)]),
            ["type": "auto_retry_start", "attempt": 1, "maxAttempts": 1, "delayMs": 0, "errorMessage": secret],
            ["type": "auto_retry_end", "success": false, "attempt": 1, "finalError": secret],
            settled()
        ]), label: "Failed retry cannot return earlier success or leak provider error")
        rejects(stream([
            end([text(secret)], reason: "error"),
            ["type": "auto_retry_start", "attempt": 1, "maxAttempts": 1, "delayMs": 0, "errorMessage": secret],
            ["type": "auto_retry_end", "success": false, "attempt": 1, "finalError": secret],
            settled()
        ]), label: "Exhausted retry is failure")



        let invalidOutputs = [
            "{}", #"{"other":"译文"}"#, #"{"one":"译文","other":"多余"}"#,
            #"{"one":"first","one":"second"}"#,
            #"{"one":"first","\u006fne":"second"}"#,
            #"{"one":null}"#, #"{"one":123}"#, #"{"one":true}"#,
            #"{"one":[]}"#, #"{"one":{}}"#, #"{"one":""}"#,
            #"{"one":" \t\n\r "}"#, "[]", "null",
            "```json\n" + valid + "\n```", valid + " trailing " + secret,
            valid + "\n" + valid, "prefix " + secret + valid
        ]
        for (index, output) in invalidOutputs.enumerated() {
            rejects(response(output), label: "Invalid response dictionary case \(index)")
        }
        rejects(response(#"{"one":"译文"}"#), ids: ["one", "one"], label: "Duplicate expected IDs")
        rejects(response(#"{"one":"译文"}"#), ids: ["one", "two"], label: "Missing one of multiple expected IDs")
        rejects(response("{\"one\":\"" + secret + "\",\"other\":\"extra\"}"), label: "Invalid dictionary errors redact response values")
        print("Pi response checks passed")
    }
}

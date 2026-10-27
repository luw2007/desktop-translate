import CoreGraphics
import Foundation
import Vision

extension DesktopCapture {
    /// Holds the in-flight Vision request so structured cancellation can cancel it from the cancellation handler.
    private final class RequestCanceller: @unchecked Sendable {
        private let lock = NSLock()
        private var request: VNRequest?
        private var cancelled = false
        func register(_ request: VNRequest) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            self.request = request; return true
        }
        func cancel() {
            lock.lock(); cancelled = true; let current = request; request = nil; lock.unlock()
            current?.cancel()
        }
        func clear() { lock.lock(); request = nil; lock.unlock() }
    }

    static func recognize(_ image: CGImage, languageCorrection: Bool, sourceLanguage: String) async throws -> [OCRObservation] {
        let canceller = RequestCanceller()
        let task = Task.detached(priority: .userInitiated) { () throws -> [OCRObservation] in
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Fixed source: Vision's recognizer for that language (+ English for Latin UI text). Auto, or a language
            // without a Vision recognizer: Vision's own automatic language detection.
            let languages = TranslationLanguages.visionLanguages(source: sourceLanguage)
            if languages.isEmpty {
                request.automaticallyDetectsLanguage = true
            } else {
                request.automaticallyDetectsLanguage = false
                request.recognitionLanguages = languages
            }
            request.usesLanguageCorrection = languageCorrection
            guard canceller.register(request) else { throw CancellationError() }
            defer { canceller.clear() }
            // The handler (and thus the image reference) lives only for this scope.
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                // Per-word boxes (normalized to the same crop) let the grouper split one Vision line that
                // spans unrelated columns or buttons. They are all-or-nothing: if any token lacks a valid box,
                // the observation carries no words at all (line-level fallback), never a partial list.
                let string = text.string
                var words: [OCRWord] = []
                var complete = true
                var index = string.startIndex
                scan: while index < string.endIndex {
                    while index < string.endIndex, string[index].isWhitespace { index = string.index(after: index) }
                    let start = index
                    while index < string.endIndex, !string[index].isWhitespace { index = string.index(after: index) }
                    guard start < index else { break }
                    guard let observed = try? text.boundingBox(for: start..<index) else { complete = false; break scan }
                    let box = observed.boundingBox
                    guard [box.minX, box.minY, box.width, box.height].allSatisfy({ $0.isFinite }), box.width > 0, box.height > 0 else {
                        complete = false; break scan
                    }
                    words.append(OCRWord(text: String(string[start..<index]), normalizedBox: box))
                }
                if !complete { words = [] }
                return OCRObservation(text: string, confidence: Double(text.confidence), normalizedBox: observation.boundingBox, words: words)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel(); canceller.cancel()
        }
    }
}

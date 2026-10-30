import Foundation
import Vision

struct AppleVisionTextBlock: Codable, Equatable, Sendable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct AppleVisionOCRFrame: Codable, Equatable, Sendable {
    let frameIndex: Int
    let blocks: [AppleVisionTextBlock]

    enum CodingKeys: String, CodingKey {
        case frameIndex = "frame_index"
        case blocks
    }

    var apiText: String {
        let lines = blocks.map { block in
            let confidence = String(format: "%.3f", block.confidence)
            let x = String(format: "%.4f", block.x)
            let y = String(format: "%.4f", block.y)
            let width = String(format: "%.4f", block.width)
            let height = String(format: "%.4f", block.height)
            return "[x=\(x) y=\(y) w=\(width) h=\(height) confidence=\(confidence)] \(block.text)"
        }
        return "FRAME \(frameIndex)\n" + (lines.isEmpty ? "[NO TEXT RECOGNIZED]" : lines.joined(separator: "\n"))
    }
}

enum AppleVisionOCRError: LocalizedError, Equatable {
    case noRecognizableFrames

    var errorDescription: String? {
        switch self {
        case .noRecognizableFrames:
            "Apple Vision did not recognize any English text in this batch."
        }
    }
}

enum AppleVisionOCR {
    static func recognize(jpeg: Data, frameIndex: Int) async throws -> AppleVisionOCRFrame {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.automaticallyDetectsLanguage = false
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: jpeg, options: [:])
            try handler.perform([request])

            let blocks = (request.results ?? []).compactMap { observation -> AppleVisionTextBlock? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return AppleVisionTextBlock(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    x: box.minX,
                    y: 1 - box.maxY,
                    width: box.width,
                    height: box.height
                )
            }.sorted { left, right in
                if abs(left.y - right.y) > 0.015 { return left.y < right.y }
                return left.x < right.x
            }
            return AppleVisionOCRFrame(frameIndex: frameIndex, blocks: blocks)
        }.value
    }
}


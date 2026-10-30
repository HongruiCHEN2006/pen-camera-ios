import CoreGraphics
import Foundation
import UIKit

struct CameraSample: Sendable {
    let jpeg: Data
    let frameNumber: Int
    let capturedAt: Date
}

enum CameraBlackFrameDetector {
    static func isBlack(_ jpeg: Data) -> Bool? {
        guard let image = UIImage(data: jpeg)?.cgImage else { return nil }
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        var darkCount = 0
        var brightnessTotal = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let brightness = (Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])) / 3
            brightnessTotal += brightness
            if brightness < 40 { darkCount += 1 }
        }
        return darkCount >= 1004 && brightnessTotal / (width * height) < 28
    }
}

@MainActor
final class CameraBatchCapture {
    static let maximumFrames = 120
    static let maximumBytes = 50 * 1_024 * 1_024

    static var rootDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "PenCameraBatches", isDirectory: true
        )
    }

    let directory: URL
    private(set) var images: [URL] = []
    private(set) var ocrFrames: [AppleVisionOCRFrame] = []
    private(set) var byteCount = 0
    private var lastJPEG: Data?

    init() throws {
        let root = Self.rootDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    init(existingDirectory: URL) throws {
        directory = existingDirectory
        images = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        byteCount = try images.reduce(0) { total, url in
            total + (try Data(contentsOf: url).count)
        }
        lastJPEG = try images.last.map { try Data(contentsOf: $0) }
    }

    static func recover() -> [CameraBatchCapture] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return directories.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? CameraBatchCapture(existingDirectory: $0) }
            .filter { !$0.images.isEmpty }
    }

    func append(_ jpeg: Data) throws -> Bool {
        if lastJPEG == jpeg { return false }
        guard images.count < Self.maximumFrames,
              byteCount + jpeg.count <= Self.maximumBytes else {
            throw BatchCaptureError.limitReached
        }
        let url = directory.appendingPathComponent(String(format: "%04d.jpg", images.count + 1))
        try jpeg.write(to: url, options: .atomic)
        images.append(url)
        byteCount += jpeg.count
        lastJPEG = jpeg
        return true
    }

    func readImages() throws -> [Data] {
        try images.map { try Data(contentsOf: $0) }
    }

    func appendOCR(_ frame: AppleVisionOCRFrame) {
        ocrFrames.removeAll { $0.frameIndex == frame.frameIndex }
        ocrFrames.append(frame)
        ocrFrames.sort { $0.frameIndex < $1.frameIndex }
    }

    func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

enum BatchCaptureError: LocalizedError {
    case limitReached

    var errorDescription: String? {
        "The batch reached 120 images or 50 MB. Cover the camera to finish and upload it."
    }
}

import Foundation

enum AnalysisUploadMode: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case images
    case appleVision = "apple_vision"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .images: "Images"
        case .appleVision: "Apple Vision"
        }
    }
}


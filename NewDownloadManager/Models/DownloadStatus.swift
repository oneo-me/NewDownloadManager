import Foundation

enum DownloadStatus: String, Codable, Sendable {
    case waiting
    case downloading
    case paused
    case completed
    case failed
    case merging

    var canPause: Bool {
        self == .downloading
    }

    var canResume: Bool {
        self == .paused || self == .failed
    }

    var canCancel: Bool {
        self == .downloading || self == .paused || self == .waiting
    }

    var displayName: String {
        switch self {
        case .waiting: "Waiting"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .merging: "Merging"
        }
    }
}

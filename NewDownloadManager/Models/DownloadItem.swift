import Foundation

struct DownloadItem: Identifiable, Codable, Sendable {
    let id: UUID
    let url: String
    var fileName: String
    let dateAdded: Date
    var status: DownloadStatus = .waiting
    var totalBytes: Int64 = 0
    var chunks: [ChunkInfo] = []
    var destinationPath: String = ""
    var errorMessage: String?
    var speed: Int64 = 0
    var eta: TimeInterval = 0

    var overallProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytesDownloaded) / Double(totalBytes)
    }

    var totalBytesDownloaded: Int64 {
        chunks.reduce(0) { $0 + $1.bytesDownloaded }
    }

    enum CodingKeys: String, CodingKey {
        case id, url, fileName, dateAdded, status, totalBytes, chunks, destinationPath, errorMessage
    }
}

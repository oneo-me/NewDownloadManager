import Foundation

struct ChunkInfo: Identifiable, Codable, Sendable {
    let id: Int
    let startByte: Int64
    let endByte: Int64
    var bytesDownloaded: Int64 = 0
    var isCompleted: Bool = false

    var totalBytes: Int64 {
        endByte - startByte + 1
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }

    var rangeHeaderValue: String {
        let resumeOffset = startByte + bytesDownloaded
        return "bytes=\(resumeOffset)-\(endByte)"
    }
}

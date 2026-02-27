import Foundation

enum Formatting {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    static func formatSpeed(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return "\(byteFormatter.string(fromByteCount: bytesPerSecond))/s"
    }

    static func formatETA(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        } else if totalSeconds < 3600 {
            let m = totalSeconds / 60
            let s = totalSeconds % 60
            return "\(m)m \(s)s"
        } else {
            let h = totalSeconds / 3600
            let m = (totalSeconds % 3600) / 60
            return "\(h)h \(m)m"
        }
    }
}

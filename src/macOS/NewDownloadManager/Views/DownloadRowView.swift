import SwiftUI

struct DownloadRowView: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusBadge
            }

            if item.status == .downloading || item.status == .paused || item.status == .merging {
                ProgressView(value: item.overallProgress)
                    .progressViewStyle(.linear)

                HStack {
                    if item.totalBytes > 0 {
                        Text("\(Formatting.formatBytes(item.totalBytesDownloaded)) / \(Formatting.formatBytes(item.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.status == .downloading, item.speed > 0 {
                        Text(Formatting.formatSpeed(item.speed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if item.status == .completed {
                Text(Formatting.formatBytes(item.totalBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if item.status == .failed, let error = item.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (color, icon) = statusInfo
        Label(item.status.displayName, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var statusInfo: (Color, String) {
        switch item.status {
        case .waiting: (.secondary, "clock")
        case .downloading: (.blue, "arrow.down.circle")
        case .paused: (.orange, "pause.circle")
        case .completed: (.green, "checkmark.circle")
        case .failed: (.red, "xmark.circle")
        case .merging: (.purple, "doc.on.doc")
        }
    }
}

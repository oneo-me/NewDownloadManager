import SwiftUI

struct DownloadDetailView: View {
    let item: DownloadItem
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // File Info
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.fileName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)

                    LabeledContent("URL") {
                        Text(item.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    LabeledContent("Status") {
                        Text(item.status.displayName)
                            .foregroundStyle(statusColor)
                    }

                    if item.totalBytes > 0 {
                        LabeledContent("Size") {
                            Text(Formatting.formatBytes(item.totalBytes))
                        }
                    }

                    LabeledContent("Destination") {
                        Text(item.destinationPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }

                    if let error = item.errorMessage {
                        LabeledContent("Error") {
                            Text(error)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Divider()

                // Progress
                VStack(alignment: .leading, spacing: 8) {
                    Text("Progress")
                        .font(.headline)

                    ProgressView(value: item.overallProgress)
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(Formatting.formatBytes(item.totalBytesDownloaded)) / \(Formatting.formatBytes(item.totalBytes))")
                            .font(.callout)
                        Text("(\(Int(item.overallProgress * 100))%)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if item.status == .downloading {
                            if item.speed > 0 {
                                Text(Formatting.formatSpeed(item.speed))
                                    .font(.callout)
                            }
                            if item.eta > 0 {
                                Text("ETA: \(Formatting.formatETA(item.eta))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Chunks
                if item.chunks.count > 1 {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chunks (\(item.chunks.count))")
                            .font(.headline)

                        ChunkProgressView(chunks: item.chunks)
                            .frame(height: 20)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 8) {
                            ForEach(item.chunks) { chunk in
                                HStack {
                                    Circle()
                                        .fill(chunk.isCompleted ? .green : chunkColor(chunk.id))
                                        .frame(width: 8, height: 8)
                                    Text("Chunk \(chunk.id + 1)")
                                        .font(.caption)
                                    Spacer()
                                    Text("\(Int(chunk.progress * 100))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Divider()

                // Actions
                HStack(spacing: 12) {
                    if item.status.canPause {
                        Button("Pause") {
                            manager.pauseDownload(item.id)
                        }
                    }
                    if item.status.canResume {
                        Button("Resume") {
                            manager.resumeDownload(item.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if item.status.canCancel {
                        Button("Cancel") {
                            manager.cancelDownload(item.id)
                        }
                    }
                    if item.status == .failed {
                        Button("Retry") {
                            manager.retryDownload(item.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if item.status == .completed {
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(item.destinationPath, inFileViewerRootedAtPath: "")
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting: .secondary
        case .downloading: .blue
        case .paused: .orange
        case .completed: .green
        case .failed: .red
        case .merging: .purple
        }
    }

    private func chunkColor(_ id: Int) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .cyan, .pink, .yellow, .mint, .indigo]
        return colors[id % colors.count]
    }
}

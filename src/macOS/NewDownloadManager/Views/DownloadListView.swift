import SwiftUI

struct DownloadListView: View {
    @Environment(DownloadManager.self) private var manager
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(manager.items) { item in
                DownloadRowView(item: item)
                    .tag(item.id)
                    .contextMenu {
                        contextMenuItems(for: item)
                    }
            }
        }
        .overlay {
            if manager.items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Click + to add a download")
                )
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: DownloadItem) -> some View {
        if item.status.canPause {
            Button("Pause") {
                manager.pauseDownload(item.id)
            }
        }
        if item.status.canResume {
            Button("Resume") {
                manager.resumeDownload(item.id)
            }
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
        }
        Divider()
        if item.status == .completed {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(item.destinationPath, inFileViewerRootedAtPath: "")
            }
        }
        Button("Delete", role: .destructive) {
            if selection == item.id {
                selection = nil
            }
            manager.deleteDownload(item.id)
        }
    }
}

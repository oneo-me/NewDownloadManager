import SwiftUI

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @State private var showAddSheet = false

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { manager.selectedItemID },
            set: { manager.selectedItemID = $0 }
        )
    }

    private var settingsSheetBinding: Binding<Bool> {
        Binding(
            get: { manager.isSettingsSheetPresented },
            set: { manager.isSettingsSheetPresented = $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            DownloadListView(selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            if let selection = manager.selectedItemID,
               let item = manager.items.first(where: { $0.id == selection }) {
                DownloadDetailView(item: item)
            } else {
                ContentUnavailableView(
                    "Select a Download",
                    systemImage: "arrow.down.circle",
                    description: Text("Choose a download from the sidebar to view details")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    manager.isSettingsSheetPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }

                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Download", systemImage: "plus")
                }

                Button {
                    manager.pauseAll()
                } label: {
                    Label("Pause All", systemImage: "pause.fill")
                }
                .disabled(!manager.items.contains { $0.status == .downloading })

                Button {
                    manager.resumeAll()
                } label: {
                    Label("Resume All", systemImage: "play.fill")
                }
                .disabled(!manager.items.contains { $0.status.canResume })
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddDownloadSheet()
        }
        .sheet(isPresented: settingsSheetBinding) {
            SettingsSheet()
        }
        .frame(minWidth: 700, minHeight: 450)
    }
}

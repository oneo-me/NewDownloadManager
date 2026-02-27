import SwiftUI

@main
struct NewDownloadManagerApp: App {
    @State private var downloadManager = DownloadManager()

    var body: some Scene {
        Window("NewDownloadManager", id: "main") {
            ContentView()
                .environment(downloadManager)
                .preferredColorScheme(downloadManager.effectiveColorScheme)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    downloadManager.isSettingsSheetPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

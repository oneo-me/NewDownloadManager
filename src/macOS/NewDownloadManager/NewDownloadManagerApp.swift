import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct AppMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("设置...") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            manager.isSettingsSheetPresented = true
        }

        Divider()

        Button("退出") {
            NSApp.terminate(nil)
        }
    }
}

@main
struct NewDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var downloadManager = DownloadManager()

    var body: some Scene {
        Window("NewDownloadManager", id: "main") {
            ContentView()
                .environment(downloadManager)
                .preferredColorScheme(downloadManager.effectiveColorScheme)
        }
        MenuBarExtra(
            "NewDownloadManager",
            systemImage: "arrow.down.circle.fill",
            isInserted: Binding(
                get: { downloadManager.isMenuBarExtraVisible },
                set: { _ in }
            )
        ) {
            AppMenuBarContent()
                .environment(downloadManager)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    if let window = NSApp.windows.first {
                        window.makeKeyAndOrderFront(nil)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    downloadManager.isSettingsSheetPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

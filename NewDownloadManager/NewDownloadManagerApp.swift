import SwiftUI

@main
struct NewDownloadManagerApp: App {
    @State private var downloadManager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(downloadManager)
        }
    }
}

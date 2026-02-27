import Foundation
import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "系统"
        case .light: return "亮色"
        case .dark: return "暗色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@Observable
final class DownloadManager {
    private static let chromeInterceptionEnabledDefaultsKey = "ChromeInterceptionEnabled"
    private static let appThemeDefaultsKey = "AppTheme"
    private static let userAgentDefaultsKey = "DownloadUserAgent"
    private static let maxConnectionsDefaultsKey = "DownloadMaxConnections"
    private static let customDownloadDirectoryDefaultsKey = "CustomDownloadDirectory"

    private static let defaultMaxConnections = 8

    static func systemDownloadsDirectoryPath() -> String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    var items: [DownloadItem] = []
    var selectedItemID: UUID?
    var isSettingsSheetPresented: Bool = false
    var chromeInterceptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(chromeInterceptionEnabled, forKey: Self.chromeInterceptionEnabledDefaultsKey)
        }
    }
    var appTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: Self.appThemeDefaultsKey)
        }
    }
    var customUserAgent: String {
        didSet {
            UserDefaults.standard.set(customUserAgent, forKey: Self.userAgentDefaultsKey)
        }
    }
    var maxDownloadConnections: Int {
        didSet {
            let clamped = max(1, min(32, maxDownloadConnections))
            if clamped != maxDownloadConnections {
                maxDownloadConnections = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.maxConnectionsDefaultsKey)
        }
    }
    var customDownloadDirectory: String {
        didSet {
            UserDefaults.standard.set(customDownloadDirectory, forKey: Self.customDownloadDirectoryDefaultsKey)
        }
    }

    private var engines: [UUID: DownloadEngine] = [:]
    private var speedTimer: Timer?
    private let extensionCommandServer = ExtensionCommandServer()
    private var lastBytesSnapshot: [UUID: Int64] = [:]
    private var pendingProgressByItem: [UUID: [Int: Int64]] = [:]

    init() {
        let initialChromeInterceptionEnabled: Bool
        if UserDefaults.standard.object(forKey: Self.chromeInterceptionEnabledDefaultsKey) == nil {
            initialChromeInterceptionEnabled = true
        } else {
            initialChromeInterceptionEnabled = UserDefaults.standard.bool(forKey: Self.chromeInterceptionEnabledDefaultsKey)
        }

        let initialCustomUserAgent = UserDefaults.standard.string(forKey: Self.userAgentDefaultsKey) ?? ""

        let initialTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: Self.appThemeDefaultsKey) ?? "") ?? .system

        let savedConnections = UserDefaults.standard.integer(forKey: Self.maxConnectionsDefaultsKey)
        let initialMaxConnections: Int
        if UserDefaults.standard.object(forKey: Self.maxConnectionsDefaultsKey) == nil || savedConnections <= 0 {
            initialMaxConnections = Self.defaultMaxConnections
        } else {
            initialMaxConnections = savedConnections
        }

        let initialCustomDirectory: String
        if let savedDirectory = UserDefaults.standard.string(forKey: Self.customDownloadDirectoryDefaultsKey),
           !savedDirectory.isEmpty {
            initialCustomDirectory = savedDirectory
        } else {
            initialCustomDirectory = ""
        }

        chromeInterceptionEnabled = initialChromeInterceptionEnabled
        appTheme = initialTheme
        customUserAgent = initialCustomUserAgent
        maxDownloadConnections = initialMaxConnections
        customDownloadDirectory = initialCustomDirectory

        loadFromDisk()
        startSpeedTimer()
        startExtensionCommandServer()
    }

    deinit {
        speedTimer?.invalidate()
        extensionCommandServer.stop()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        items = PersistenceService.load()
        for i in items.indices {
            if items[i].status == .downloading || items[i].status == .merging {
                items[i].status = .paused
            }
        }
        saveToDisk()
    }

    private func saveToDisk() {
        PersistenceService.save(items)
    }

    // MARK: - Speed Tracking

    private func startSpeedTimer() {
        for item in items {
            lastBytesSnapshot[item.id] = item.totalBytesDownloaded
        }
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSpeed()
            }
        }
    }

    private func startExtensionCommandServer() {
        extensionCommandServer.interceptionEnabledProvider = { [weak self] in
            self?.chromeInterceptionEnabled ?? true
        }

        extensionCommandServer.onIncomingDownload = { [weak self] request in
            let normalizedURL = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedURL.isEmpty else { return }
            guard let self else { return }

            let id = self.addDownload(
                url: normalizedURL,
                fileName: request.filename,
                destinationPath: nil,
                requestHeaders: nil,
                revealInUI: true
            )
            self.revealDownloadInUI(id)
        }
        extensionCommandServer.start()
    }

    private func revealDownloadInUI(_ id: UUID) {
        selectedItemID = id

        if let keyWindow = NSApp.windows.first {
            keyWindow.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateSpeed() {
        for i in items.indices {
            let id = items[i].id
            let current = items[i].totalBytesDownloaded
            let last = lastBytesSnapshot[id] ?? current
            let bytesInInterval = current - last
            let speed = bytesInInterval * 2 // 0.5s interval -> per second
            items[i].speed = max(0, speed)
            lastBytesSnapshot[id] = current

            if items[i].status == .downloading, speed > 0 {
                let remaining = items[i].totalBytes - current
                items[i].eta = Double(remaining) / Double(speed)
            } else {
                items[i].eta = 0
            }
        }
    }

    // MARK: - Actions

    @discardableResult
    func addDownload(
        url: String,
        fileName: String?,
        destinationPath: String?,
        requestHeaders: [String: String]? = nil,
        revealInUI: Bool = false
    ) -> UUID {
        let name = fileName ?? URL(string: url)?.lastPathComponent ?? "download"
        let dest: String
        if let destinationPath, !destinationPath.isEmpty {
            dest = destinationPath
        } else {
            let baseDirectory = resolvedDefaultDownloadDirectory()
            dest = URL(fileURLWithPath: baseDirectory, isDirectory: true).appendingPathComponent(name).path
        }

        let id = UUID()
        let item = DownloadItem(
            id: id,
            url: url,
            fileName: name,
            dateAdded: Date(),
            destinationPath: dest,
            requestHeaders: requestHeaders
        )
        items.append(item)
        if revealInUI {
            selectedItemID = id
        }
        saveToDisk()
        startDownload(id)
        return id
    }

    func startDownload(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard let url = URL(string: items[index].url) else {
            items[index].status = .failed
            items[index].errorMessage = "Invalid URL"
            saveToDisk()
            return
        }

        items[index].status = .downloading
        items[index].errorMessage = nil
        lastBytesSnapshot[id] = items[index].totalBytesDownloaded
        saveToDisk()

        let existingChunks = items[index].chunks.isEmpty ? nil : items[index].chunks

        let engine = DownloadEngine(
            itemId: id,
            onProgress: { [weak self] itemId, chunkIndex, bytesWritten in
                Task { @MainActor [weak self] in
                    self?.handleProgress(itemId: itemId, chunkIndex: chunkIndex, bytesWritten: bytesWritten)
                }
            },
            onChunkComplete: { [weak self] itemId, chunkIndex in
                Task { @MainActor [weak self] in
                    self?.handleChunkComplete(itemId: itemId, chunkIndex: chunkIndex)
                }
            },
            onAllComplete: { [weak self] itemId in
                Task { @MainActor [weak self] in
                    self?.handleAllComplete(itemId: itemId)
                }
            },
            onError: { [weak self] itemId, message in
                Task { @MainActor [weak self] in
                    self?.handleError(itemId: itemId, message: message)
                }
            },
            onMetadata: { [weak self] itemId, totalBytes, chunks in
                Task { @MainActor [weak self] in
                    self?.handleMetadata(itemId: itemId, totalBytes: totalBytes, chunks: chunks)
                }
            },
            requestHeaders: items[index].requestHeaders,
            defaultUserAgent: effectiveUserAgent,
            maxParallelConnections: maxDownloadConnections
        )

        engines[id] = engine
        engine.start(url: url, existingChunks: existingChunks)
    }

    func pauseDownload(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status.canPause else { return }

        engines[id]?.pause()
        engines.removeValue(forKey: id)

        items[index].status = .paused
        items[index].speed = 0
        items[index].eta = 0
        saveToDisk()
    }

    func resumeDownload(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status.canResume else { return }

        startDownload(id)
    }

    func cancelDownload(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status.canCancel else { return }

        engines[id]?.cancel()
        engines.removeValue(forKey: id)

        items[index].status = .failed
        items[index].errorMessage = "Cancelled"
        items[index].chunks = []
        items[index].speed = 0
        items[index].eta = 0
        pendingProgressByItem[id] = nil
        saveToDisk()
    }

    func deleteDownload(_ id: UUID) {
        engines[id]?.cancel()
        engines.removeValue(forKey: id)
        items.removeAll { $0.id == id }
        if selectedItemID == id {
            selectedItemID = nil
        }
        lastBytesSnapshot.removeValue(forKey: id)
        pendingProgressByItem[id] = nil
        saveToDisk()
    }

    func retryDownload(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].chunks = []
        items[index].totalBytes = 0
        items[index].errorMessage = nil
        pendingProgressByItem[id] = nil
        startDownload(id)
    }

    func pauseAll() {
        for item in items where item.status == .downloading {
            pauseDownload(item.id)
        }
    }

    func resumeAll() {
        for item in items where item.status.canResume {
            resumeDownload(item.id)
        }
    }

    func resetDownloadSettingsToDefault() {
        appTheme = .system
        customUserAgent = ""
        maxDownloadConnections = Self.defaultMaxConnections
        customDownloadDirectory = ""
    }

    // MARK: - Callbacks

    private func handleProgress(itemId: UUID, chunkIndex: Int, bytesWritten: Int64) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard let chunkIdx = items[index].chunks.firstIndex(where: { $0.id == chunkIndex }) else {
            var pending = pendingProgressByItem[itemId] ?? [:]
            pending[chunkIndex, default: 0] += bytesWritten
            pendingProgressByItem[itemId] = pending
            return
        }

        items[index].chunks[chunkIdx].bytesDownloaded += bytesWritten
    }

    private func handleChunkComplete(itemId: UUID, chunkIndex: Int) {
        guard let index = items.firstIndex(where: { $0.id == itemId }),
              let chunkIdx = items[index].chunks.firstIndex(where: { $0.id == chunkIndex }) else { return }
        items[index].chunks[chunkIdx].isCompleted = true
        saveToDisk()
    }

    private func handleMetadata(itemId: UUID, totalBytes: Int64, chunks: [ChunkInfo]) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].totalBytes = totalBytes
        let current = items[index].chunks
        let shouldReplaceChunks =
            current.isEmpty ||
            current.count != chunks.count ||
            zip(current, chunks).contains { lhs, rhs in
                lhs.id != rhs.id || lhs.startByte != rhs.startByte || lhs.endByte != rhs.endByte
            }
        if shouldReplaceChunks {
            items[index].chunks = chunks
        }

        if let pending = pendingProgressByItem[itemId], !pending.isEmpty {
            for (chunkID, bytes) in pending {
                if let chunkIdx = items[index].chunks.firstIndex(where: { $0.id == chunkID }) {
                    items[index].chunks[chunkIdx].bytesDownloaded += bytes
                }
            }
            pendingProgressByItem[itemId] = nil
        }

        saveToDisk()
    }

    private func handleAllComplete(itemId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        pendingProgressByItem[itemId] = nil
        items[index].status = .merging
        items[index].speed = 0
        items[index].eta = 0

        let item = items[index]
        let engine = engines[itemId]

        Task.detached {
            do {
                let chunkFiles = item.chunks.sorted(by: { $0.id < $1.id }).map { chunk in
                    engine?.chunkFilePath(for: chunk.id) ?? DownloadEngine.tempDirectory.appendingPathComponent("\(itemId.uuidString)_chunk_\(chunk.id)")
                }
                let destURL = URL(fileURLWithPath: item.destinationPath)
                try FileMerger.merge(chunkFiles: chunkFiles, to: destURL)
                FileMerger.cleanupChunks(chunkFiles)

                Task { @MainActor [weak self] in
                    guard let self,
                          let idx = self.items.firstIndex(where: { $0.id == itemId }) else { return }
                    self.items[idx].status = .completed
                    self.engines.removeValue(forKey: itemId)
                    self.saveToDisk()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self,
                          let idx = self.items.firstIndex(where: { $0.id == itemId }) else { return }
                    self.items[idx].status = .failed
                    self.items[idx].errorMessage = "Merge failed: \(error.localizedDescription)"
                    self.engines.removeValue(forKey: itemId)
                    self.saveToDisk()
                }
            }
        }
    }

    private func handleError(itemId: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        pendingProgressByItem[itemId] = nil
        items[index].status = .failed
        items[index].errorMessage = message
        items[index].speed = 0
        items[index].eta = 0
        engines.removeValue(forKey: itemId)
        saveToDisk()
    }

    private var effectiveUserAgent: String {
        let trimmed = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? DownloadEngine.fallbackUserAgent : trimmed
    }

    var effectiveColorScheme: ColorScheme? {
        appTheme.colorScheme
    }

    var defaultDownloadDirectoryPlaceholder: String {
        Self.systemDownloadsDirectoryPath()
    }

    private func resolvedDefaultDownloadDirectory() -> String {
        let trimmed = customDownloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? Self.systemDownloadsDirectoryPath() : trimmed

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }

        let fallback = Self.systemDownloadsDirectoryPath()
        customDownloadDirectory = ""
        return fallback
    }
}

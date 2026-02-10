import Foundation
import SwiftUI

@Observable
final class DownloadManager {
    var items: [DownloadItem] = []
    private var engines: [UUID: DownloadEngine] = [:]
    private var speedTimer: Timer?
    private var lastBytesSnapshot: [UUID: Int64] = [:]

    init() {
        loadFromDisk()
        startSpeedTimer()
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

    func addDownload(url: String, fileName: String?, destinationPath: String?) {
        let name = fileName ?? URL(string: url)?.lastPathComponent ?? "download"
        let dest: String
        if let destinationPath, !destinationPath.isEmpty {
            dest = destinationPath
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            dest = downloads.appendingPathComponent(name).path
        }

        let item = DownloadItem(
            id: UUID(),
            url: url,
            fileName: name,
            dateAdded: Date(),
            destinationPath: dest
        )
        items.append(item)
        saveToDisk()
        startDownload(item.id)
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
            }
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
        saveToDisk()
    }

    func deleteDownload(_ id: UUID) {
        engines[id]?.cancel()
        engines.removeValue(forKey: id)
        items.removeAll { $0.id == id }
        lastBytesSnapshot.removeValue(forKey: id)
        saveToDisk()
    }

    func retryDownload(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].chunks = []
        items[index].totalBytes = 0
        items[index].errorMessage = nil
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

    // MARK: - Callbacks

    private func handleProgress(itemId: UUID, chunkIndex: Int, bytesWritten: Int64) {
        guard let index = items.firstIndex(where: { $0.id == itemId }),
              let chunkIdx = items[index].chunks.firstIndex(where: { $0.id == chunkIndex }) else { return }
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
        if items[index].chunks.isEmpty {
            items[index].chunks = chunks
        }
        saveToDisk()
    }

    private func handleAllComplete(itemId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
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
        items[index].status = .failed
        items[index].errorMessage = message
        items[index].speed = 0
        items[index].eta = 0
        engines.removeValue(forKey: itemId)
        saveToDisk()
    }
}

import Foundation

final class DownloadEngine: Sendable {
    let itemId: UUID
    private let sessionDelegate = ChunkDownloadSessionDelegate()
    nonisolated(unsafe) private var session: URLSession?
    nonisolated(unsafe) private var downloaders: [ChunkDownloader] = []
    nonisolated(unsafe) private var completedChunks = 0
    nonisolated(unsafe) private var totalChunks = 0
    nonisolated(unsafe) private var isCancelled = false
    private let lock = NSLock()

    private let onProgress: @Sendable (UUID, Int, Int64) -> Void
    private let onChunkComplete: @Sendable (UUID, Int) -> Void
    private let onAllComplete: @Sendable (UUID) -> Void
    private let onError: @Sendable (UUID, String) -> Void
    private let onMetadata: @Sendable (UUID, Int64, [ChunkInfo]) -> Void

    init(
        itemId: UUID,
        onProgress: @escaping @Sendable (UUID, Int, Int64) -> Void,
        onChunkComplete: @escaping @Sendable (UUID, Int) -> Void,
        onAllComplete: @escaping @Sendable (UUID) -> Void,
        onError: @escaping @Sendable (UUID, String) -> Void,
        onMetadata: @escaping @Sendable (UUID, Int64, [ChunkInfo]) -> Void
    ) {
        self.itemId = itemId
        self.onProgress = onProgress
        self.onChunkComplete = onChunkComplete
        self.onAllComplete = onAllComplete
        self.onError = onError
        self.onMetadata = onMetadata
    }

    static var tempDirectory: URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("NewDownloadManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func chunkFilePath(for chunkIndex: Int) -> URL {
        Self.tempDirectory.appendingPathComponent("\(itemId.uuidString)_chunk_\(chunkIndex)")
    }

    func start(url: URL, existingChunks: [ChunkInfo]?) {
        lock.lock()
        isCancelled = false
        lock.unlock()

        if let chunks = existingChunks, !chunks.isEmpty {
            resumeDownload(url: url, chunks: chunks)
        } else {
            fetchMetadataAndStart(url: url)
        }
    }

    private func fetchMetadataAndStart(url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let metaSession = URLSession(configuration: .ephemeral)
        let task = metaSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }

            self.lock.lock()
            if self.isCancelled {
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            if let error {
                self.onError(self.itemId, error.localizedDescription)
                return
            }

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.onError(self.itemId, "HTTP error \(code)")
                return
            }

            let contentLength = http.expectedContentLength
            let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")
            let supportsRange = acceptRanges?.lowercased() == "bytes" && contentLength > 0

            let chunks: [ChunkInfo]
            if supportsRange, contentLength > 0 {
                chunks = Self.createChunks(totalBytes: contentLength)
            } else {
                let total = max(contentLength, 0)
                chunks = [ChunkInfo(id: 0, startByte: 0, endByte: total > 0 ? total - 1 : Int64.max)]
            }

            self.onMetadata(self.itemId, max(contentLength, 0), chunks)
            self.startChunkDownloads(url: url, chunks: chunks)
        }
        task.resume()
    }

    private func resumeDownload(url: URL, chunks: [ChunkInfo]) {
        let pending = chunks.filter { !$0.isCompleted }
        if pending.isEmpty {
            onAllComplete(itemId)
            return
        }
        startChunkDownloads(url: url, chunks: chunks)
    }

    static func createChunks(totalBytes: Int64) -> [ChunkInfo] {
        let minChunkSize: Int64 = 256 * 1024
        let maxChunks = 8
        let chunkCount = max(1, min(maxChunks, Int(totalBytes / minChunkSize)))
        let chunkSize = totalBytes / Int64(chunkCount)

        return (0..<chunkCount).map { i in
            let start = Int64(i) * chunkSize
            let end = (i == chunkCount - 1) ? (totalBytes - 1) : (start + chunkSize - 1)
            return ChunkInfo(id: i, startByte: start, endByte: end)
        }
    }

    private func startChunkDownloads(url: URL, chunks: [ChunkInfo]) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            return
        }

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        let urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        session = urlSession

        let pending = chunks.filter { !$0.isCompleted }
        totalChunks = pending.count
        completedChunks = 0

        var newDownloaders: [ChunkDownloader] = []
        for chunk in pending {
            let downloader = ChunkDownloader(
                chunkIndex: chunk.id,
                url: url,
                range: chunk.rangeHeaderValue,
                filePath: chunkFilePath(for: chunk.id),
                onProgress: { [weak self] index, bytes in
                    guard let self else { return }
                    self.onProgress(self.itemId, index, bytes)
                },
                onComplete: { [weak self] index, result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.onChunkComplete(self.itemId, index)
                        self.lock.lock()
                        self.completedChunks += 1
                        let allDone = self.completedChunks >= self.totalChunks
                        self.lock.unlock()
                        if allDone {
                            self.onAllComplete(self.itemId)
                        }
                    case .failure(let error):
                        switch error {
                        case .cancelled:
                            break
                        default:
                            self.onError(self.itemId, "Chunk \(index) failed: \(error)")
                        }
                    }
                }
            )
            newDownloaders.append(downloader)
        }
        downloaders = newDownloaders
        lock.unlock()

        for downloader in newDownloaders {
            downloader.start(session: urlSession, delegate: sessionDelegate)
        }
    }

    func pause() {
        lock.lock()
        isCancelled = true
        let currentDownloaders = downloaders
        let currentSession = session
        downloaders = []
        session = nil
        lock.unlock()

        sessionDelegate.clear()
        for d in currentDownloaders {
            d.cancel()
        }
        currentSession?.invalidateAndCancel()
    }

    func cancel() {
        pause()

        let fm = FileManager.default
        let tempDir = Self.tempDirectory
        let prefix = itemId.uuidString
        if let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? fm.removeItem(at: file)
            }
        }
    }
}

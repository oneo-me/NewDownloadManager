import Foundation

final class DownloadEngine: Sendable {
    static let fallbackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36"

    let itemId: UUID
    private let sessionDelegate = ChunkDownloadSessionDelegate()
    nonisolated(unsafe) private var session: URLSession?
    nonisolated(unsafe) private var downloaders: [ChunkDownloader] = []
    nonisolated(unsafe) private var completedChunks = 0
    nonisolated(unsafe) private var totalChunks = 0
    nonisolated(unsafe) private var isCancelled = false
    nonisolated(unsafe) private var hasTriggeredSingleConnectionFallback = false
    nonisolated(unsafe) private var knownTotalBytes: Int64 = 0
    private let lock = NSLock()

    private let onProgress: @Sendable (UUID, Int, Int64) -> Void
    private let onChunkComplete: @Sendable (UUID, Int) -> Void
    private let onAllComplete: @Sendable (UUID) -> Void
    private let onError: @Sendable (UUID, String) -> Void
    private let onMetadata: @Sendable (UUID, Int64, [ChunkInfo]) -> Void
    private let requestHeaders: [String: String]
    private let defaultUserAgent: String
    private let maxParallelConnections: Int

    init(
        itemId: UUID,
        onProgress: @escaping @Sendable (UUID, Int, Int64) -> Void,
        onChunkComplete: @escaping @Sendable (UUID, Int) -> Void,
        onAllComplete: @escaping @Sendable (UUID) -> Void,
        onError: @escaping @Sendable (UUID, String) -> Void,
        onMetadata: @escaping @Sendable (UUID, Int64, [ChunkInfo]) -> Void,
        requestHeaders: [String: String]? = nil,
        defaultUserAgent: String = DownloadEngine.fallbackUserAgent,
        maxParallelConnections: Int = 8
    ) {
        self.itemId = itemId
        self.onProgress = onProgress
        self.onChunkComplete = onChunkComplete
        self.onAllComplete = onAllComplete
        self.onError = onError
        self.onMetadata = onMetadata
        self.requestHeaders = requestHeaders ?? [:]
        self.defaultUserAgent = defaultUserAgent
        self.maxParallelConnections = max(1, min(32, maxParallelConnections))
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
        hasTriggeredSingleConnectionFallback = false
        knownTotalBytes = 0
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
        applyRequestHeaders(to: &request, includeRange: false)

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
                if self.shouldFallbackToSingleConnection(forStatusCode: code) {
                    self.startSingleConnectionDownload(url: url, totalBytes: 0)
                    return
                }
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
                // Non-range mode: keep an open-ended chunk so downloader can omit Range header.
                chunks = [ChunkInfo(id: 0, startByte: 0, endByte: Int64.max)]
            }

            self.lock.lock()
            self.knownTotalBytes = max(contentLength, 0)
            self.lock.unlock()

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
        config.httpMaximumConnectionsPerHost = maxParallelConnections
        let urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        session = urlSession

        let pending = chunks.filter { !$0.isCompleted }
        totalChunks = pending.count
        completedChunks = 0

        var newDownloaders: [ChunkDownloader] = []
        for chunk in pending {
            let rangeHeader = chunk.endByte == Int64.max ? nil : chunk.rangeHeaderValue
            let downloader = ChunkDownloader(
                chunkIndex: chunk.id,
                url: url,
                range: rangeHeader,
                requestHeaders: requestHeaders,
                defaultUserAgent: defaultUserAgent,
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
                        case .httpError(let statusCode):
                            if self.shouldFallbackFromChunkFailure(statusCode: statusCode, chunkCount: chunks.count) {
                                self.startSingleConnectionDownload(url: url, totalBytes: self.knownTotalBytes)
                            } else {
                                self.onError(self.itemId, "Chunk \(index) failed: \(error)")
                            }
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

    private func shouldFallbackToSingleConnection(forStatusCode statusCode: Int) -> Bool {
        statusCode == 403 || statusCode == 429 || statusCode == 405
    }

    private func shouldFallbackFromChunkFailure(statusCode: Int, chunkCount: Int) -> Bool {
        guard chunkCount > 1 else { return false }
        return shouldFallbackToSingleConnection(forStatusCode: statusCode)
    }

    private func startSingleConnectionDownload(url: URL, totalBytes: Int64) {
        lock.lock()
        if isCancelled || hasTriggeredSingleConnectionFallback {
            lock.unlock()
            return
        }
        hasTriggeredSingleConnectionFallback = true
        let currentDownloaders = downloaders
        let currentSession = session
        downloaders = []
        session = nil
        lock.unlock()

        sessionDelegate.clear()
        for downloader in currentDownloaders {
            downloader.cancel()
        }
        currentSession?.invalidateAndCancel()

        cleanupChunkFiles()

        let singleChunk = ChunkInfo(id: 0, startByte: 0, endByte: Int64.max)
        onMetadata(itemId, max(totalBytes, 0), [singleChunk])

        lock.lock()
        if isCancelled {
            lock.unlock()
            return
        }

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        let urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        session = urlSession
        totalChunks = 1
        completedChunks = 0

        let downloader = ChunkDownloader(
            chunkIndex: singleChunk.id,
            url: url,
            range: nil,
            requestHeaders: requestHeaders,
            defaultUserAgent: defaultUserAgent,
            filePath: chunkFilePath(for: singleChunk.id),
            onProgress: { [weak self] index, bytes in
                guard let self else { return }
                self.onProgress(self.itemId, index, bytes)
            },
            onComplete: { [weak self] index, result in
                guard let self else { return }
                switch result {
                case .success:
                    self.onChunkComplete(self.itemId, index)
                    self.onAllComplete(self.itemId)
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
        downloaders = [downloader]
        lock.unlock()

        downloader.start(session: urlSession, delegate: sessionDelegate)
    }

    private func cleanupChunkFiles() {
        let fm = FileManager.default
        let tempDir = Self.tempDirectory
        let prefix = itemId.uuidString
        if let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func applyRequestHeaders(to request: inout URLRequest, includeRange: Bool) {
        var hasUserAgent = false

        for (name, value) in requestHeaders {
            let lower = name.lowercased()
            if Self.blockedHeaderNames.contains(lower) {
                continue
            }
            if !includeRange && lower == "range" {
                continue
            }
            if lower == "user-agent" {
                hasUserAgent = true
            }
            request.setValue(value, forHTTPHeaderField: name)
        }

        if !hasUserAgent {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
    }

    private static let blockedHeaderNames: Set<String> = [
        "connection",
        "content-length",
        "host",
        "keep-alive",
        "proxy-connection",
        "te",
        "transfer-encoding",
        "upgrade"
    ]

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
        cleanupChunkFiles()
    }
}

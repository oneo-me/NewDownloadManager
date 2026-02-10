import Foundation

enum ChunkDownloadError: Error, Sendable {
    case httpError(statusCode: Int)
    case fileWriteError(Error)
    case cancelled
    case unknown(Error)
}

final class ChunkDownloader: NSObject, Sendable {
    let chunkIndex: Int
    let url: URL
    let range: String
    let filePath: URL

    nonisolated(unsafe) private var fileHandle: FileHandle?
    nonisolated(unsafe) private var dataTask: URLSessionDataTask?
    nonisolated(unsafe) private var isCancelled = false

    private let lock = NSLock()
    private let onProgress: @Sendable (Int, Int64) -> Void
    private let onComplete: @Sendable (Int, Result<Void, ChunkDownloadError>) -> Void

    init(
        chunkIndex: Int,
        url: URL,
        range: String,
        filePath: URL,
        onProgress: @escaping @Sendable (Int, Int64) -> Void,
        onComplete: @escaping @Sendable (Int, Result<Void, ChunkDownloadError>) -> Void
    ) {
        self.chunkIndex = chunkIndex
        self.url = url
        self.range = range
        self.filePath = filePath
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func start(session: URLSession) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }

        if !FileManager.default.fileExists(atPath: filePath.path) {
            FileManager.default.createFile(atPath: filePath.path, contents: nil)
        }
        do {
            fileHandle = try FileHandle(forWritingTo: filePath)
            fileHandle?.seekToEndOfFile()
        } catch {
            lock.unlock()
            onComplete(chunkIndex, .failure(.fileWriteError(error)))
            return
        }

        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        dataTask = task
        lock.unlock()

        task.resume()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = dataTask
        let handle = fileHandle
        dataTask = nil
        fileHandle = nil
        lock.unlock()

        task?.cancel()
        try? handle?.close()
    }

    fileprivate func didReceiveResponse(_ response: URLResponse) -> Bool {
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            onComplete(chunkIndex, .failure(.httpError(statusCode: http.statusCode)))
            return false
        }
        return true
    }

    fileprivate func didReceiveData(_ data: Data) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        let handle = fileHandle
        lock.unlock()

        do {
            try handle?.write(contentsOf: data)
            onProgress(chunkIndex, Int64(data.count))
        } catch {
            onComplete(chunkIndex, .failure(.fileWriteError(error)))
        }
    }

    fileprivate func didComplete(error: Error?) {
        lock.lock()
        let handle = fileHandle
        let cancelled = isCancelled
        fileHandle = nil
        lock.unlock()

        try? handle?.close()

        if cancelled {
            return
        }

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            onComplete(chunkIndex, .failure(.unknown(error)))
        } else {
            onComplete(chunkIndex, .success(()))
        }
    }
}

final class ChunkDownloadSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let downloaders: NSLock = NSLock()
    nonisolated(unsafe) private var taskMap: [Int: ChunkDownloader] = [:]

    func register(_ downloader: ChunkDownloader, for task: URLSessionDataTask) {
        downloaders.lock()
        taskMap[task.taskIdentifier] = downloader
        downloaders.unlock()
    }

    func registerByChunkIndex(_ downloader: ChunkDownloader, taskIdentifier: Int) {
        downloaders.lock()
        taskMap[taskIdentifier] = downloader
        downloaders.unlock()
    }

    func clear() {
        downloaders.lock()
        taskMap.removeAll()
        downloaders.unlock()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        downloaders.lock()
        let downloader = taskMap[dataTask.taskIdentifier]
        downloaders.unlock()

        if let downloader, !downloader.didReceiveResponse(response) {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        downloaders.lock()
        let downloader = taskMap[dataTask.taskIdentifier]
        downloaders.unlock()

        downloader?.didReceiveData(data)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        downloaders.lock()
        let downloader = taskMap[task.taskIdentifier]
        taskMap.removeValue(forKey: task.taskIdentifier)
        downloaders.unlock()

        downloader?.didComplete(error: error)
    }
}

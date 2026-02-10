import Foundation

enum FileMerger {
    static let bufferSize = 1024 * 1024 // 1MB

    static func merge(chunkFiles: [URL], to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: destination)
        defer { try? outputHandle.close() }

        for chunkFile in chunkFiles {
            let inputHandle = try FileHandle(forReadingFrom: chunkFile)
            defer { try? inputHandle.close() }

            while true {
                let data = inputHandle.readData(ofLength: bufferSize)
                if data.isEmpty { break }
                outputHandle.write(data)
            }
        }
    }

    static func cleanupChunks(_ chunkFiles: [URL]) {
        let fm = FileManager.default
        for file in chunkFiles {
            try? fm.removeItem(at: file)
        }
    }
}

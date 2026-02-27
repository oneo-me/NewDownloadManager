import Foundation
import Network

final class ExtensionCommandServer {
    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    struct IncomingDownload: Decodable {
        let type: String?
        let url: String
        let filename: String?
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "NewDownloadManager.ExtensionCommandServer")
    private let port: NWEndpoint.Port = 48652

    var onIncomingDownload: ((IncomingDownload) -> Void)?
    var interceptionEnabledProvider: (() -> Bool)?

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
        } catch {
            print("Failed to start extension command server: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("Extension command server listening on port \(self.port)")
            case .failed(let error):
                print("Extension command server failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                self.receiveAll(from: connection, buffer: Data())
            }
        }

        connection.start(queue: queue)
    }

    private func receiveAll(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                print("Extension command server receive error: \(error)")
                connection.cancel()
                return
            }

            var merged = buffer
            if let data, !data.isEmpty {
                merged.append(data)
            }

            do {
                if let request = try self.parseHTTPRequest(from: merged) {
                    self.handleRequest(request, on: connection)
                    return
                }
            } catch {
                self.sendTextResponse(statusCode: 400, body: "invalid request", on: connection)
                return
            }

            if isComplete {
                self.sendTextResponse(statusCode: 400, body: "incomplete request", on: connection)
                return
            }

            self.receiveAll(from: connection, buffer: merged)
        }
    }

    private func parseHTTPRequest(from payload: Data) throws -> HTTPRequest? {
        let separator = Data([13, 10, 13, 10]) // \r\n\r\n
        guard let headerRange = payload.range(of: separator) else {
            return nil
        }

        let headerData = payload.subdata(in: payload.startIndex..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw NSError(domain: "ExtensionCommandServer", code: 1)
        }

        let headerLines = headerString
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
        guard let requestLine = headerLines.first else {
            throw NSError(domain: "ExtensionCommandServer", code: 2)
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw NSError(domain: "ExtensionCommandServer", code: 3)
        }

        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for lineString in headerLines.dropFirst() {
            let lower = lineString.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = lineString.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                if value.count == 2 {
                    let raw = value[1].trimmingCharacters(in: .whitespaces)
                    contentLength = Int(raw) ?? 0
                }
            }
        }

        let bodyStart = headerRange.upperBound
        let availableBodyBytes = payload.count - bodyStart
        guard availableBodyBytes >= contentLength else {
            return nil
        }

        let bodyEnd = bodyStart + contentLength
        let body = payload.subdata(in: bodyStart..<bodyEnd)
        return HTTPRequest(method: method, path: path, body: body)
    }

    private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) {
        let method = request.method
        let path = request.path

        if method == "OPTIONS" {
            sendTextResponse(statusCode: 204, body: "", on: connection)
            return
        }

        if method == "GET" && path == "/interception/status" {
            let enabled = interceptionEnabledProvider?() ?? true
            sendJSONResponse(statusCode: 200, jsonBody: ["chromeInterceptionEnabled": enabled], on: connection)
            return
        }

        if method == "POST" && path == "/downloads/intercepted" {
            guard (interceptionEnabledProvider?() ?? true) else {
                sendTextResponse(statusCode: 403, body: "interception disabled", on: connection)
                return
            }

            let bodyData = request.body
            guard !bodyData.isEmpty else {
                sendTextResponse(statusCode: 400, body: "invalid body", on: connection)
                return
            }

            let decoder = JSONDecoder()
            guard let incoming = try? decoder.decode(IncomingDownload.self, from: bodyData) else {
                sendTextResponse(statusCode: 400, body: "invalid json", on: connection)
                return
            }

            if incoming.type != nil && incoming.type != "download.intercepted" {
                sendTextResponse(statusCode: 202, body: "ignored", on: connection)
                return
            }

            DispatchQueue.main.async {
                self.onIncomingDownload?(incoming)
            }

            sendTextResponse(statusCode: 200, body: "ok", on: connection)
            return
        }

        sendTextResponse(statusCode: 404, body: "not found", on: connection)
    }

    private func sendJSONResponse(statusCode: Int, jsonBody: [String: Any], on connection: NWConnection) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        } catch {
            sendTextResponse(statusCode: 500, body: "json encoding failed", on: connection)
            return
        }

        sendResponse(statusCode: statusCode, contentType: "application/json; charset=utf-8", bodyData: data, on: connection)
    }

    private func sendTextResponse(statusCode: Int, body: String, on connection: NWConnection) {
        sendResponse(
            statusCode: statusCode,
            contentType: "text/plain; charset=utf-8",
            bodyData: Data(body.utf8),
            on: connection
        )
    }

    private func sendResponse(statusCode: Int, contentType: String, bodyData: Data, on connection: NWConnection) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        default: statusText = "Internal Server Error"
        }

        var header = ""
        header += "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        let payload = Data(header.utf8) + bodyData
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

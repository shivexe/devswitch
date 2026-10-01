// Adapted from the user-owned Harbor local transport.
import Foundation
import Network

struct HTTPRequest {
    let path: String
    let body: Data
    var remoteHost: String? = nil
}

struct HTTPResponse {
    let status: Int
    let body: Data
    init(_ status: Int, _ body: Data = Data("{}".utf8)) {
        self.status = status
        self.body = body
    }
    static func json<T: Encodable>(_ status: Int, _ value: T) throws -> HTTPResponse {
        HTTPResponse(status, try JSONEncoder().encode(value))
    }
}

@MainActor
final class HTTPServer {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let handler: (HTTPRequest) -> HTTPResponse
    var ready: (() -> Void)?
    var failed: ((String) -> Void)?

    init(handler: @escaping (HTTPRequest) -> HTTPResponse) { self.handler = handler }

    func start(port: UInt16) throws {
        stop()
        guard let port = NWEndpoint.Port(rawValue: port) else { throw AppError.message("Invalid sharing port.") }
        let listener = try NWListener(using: .tcp, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.ready?() }
                if case .failed(let error) = state { self?.stop(); self?.failed?(error.localizedDescription) }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        self.listener = listener
        listener.service = NWListener.Service(name: "DevSwitch", type: "_devswitch._tcp")
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.connections[id] != nil else { return }
            self.finish(connection, id: id)
        }
        receive(connection, id: id, bytes: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var bytes = bytes
                if let data { bytes.append(data) }
                do {
                    if var request = try Self.parse(bytes) {
                        if case let .hostPort(host, _) = connection.endpoint { request.remoteHost = "\(host)" }
                        self.respond(self.handler(request), connection: connection, id: id)
                    } else if complete || error != nil { self.finish(connection, id: id) }
                    else { self.receive(connection, id: id, bytes: bytes) }
                } catch { self.respond(HTTPResponse(400), connection: connection, id: id) }
            }
        }
    }

    static func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 32 * 1024 + 16 * 1024 else { throw AppError.message("Request too large.") }
        guard let delimiter = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16 * 1024 else { throw AppError.message("Headers too large.") }
            return nil
        }
        guard delimiter.lowerBound <= 16 * 1024,
              let header = String(data: data.prefix(delimiter.lowerBound), encoding: .utf8) else { throw AppError.message("Invalid headers.") }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[0] == "POST", first[2] == "HTTP/1.1", first[1].hasPrefix("/"), first[1].count <= 160 else { throw AppError.message("Invalid request.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw AppError.message("Invalid header.") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, headers[name] == nil else { throw AppError.message("Duplicate header.") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, let lengthString = headers["content-length"],
              !lengthString.isEmpty, lengthString.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(lengthString), length <= 32 * 1024,
              headers["content-type"]?.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else { throw AppError.message("Invalid framing.") }
        let available = data.count - delimiter.upperBound
        guard available <= length else { throw AppError.message("Unexpected request data.") }
        guard available == length else { return nil }
        return HTTPRequest(path: String(first[1]), body: Data(data.suffix(length)))
    }

    private func respond(_ response: HTTPResponse, connection: NWConnection, id: UUID) {
        let response = response.body.count <= 64 * 1024 ? response : HTTPResponse(500)
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 410: "Gone", 429: "Too Many Requests", 500: "Internal Server Error", 503: "Unavailable"][response.status] ?? "Error"
        let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(connection, id: id) }
        })
    }

    private func finish(_ connection: NWConnection, id: UUID) {
        connection.cancel()
        connections.removeValue(forKey: id)
    }
}

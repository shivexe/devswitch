import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

// Encrypted chunked file channel (research §4.2). The phone always initiates:
//   POST /v2/file/<transferId>/<index>       phone→Mac chunk, body nonce‖ciphertext‖tag
//   POST /v2/file/<transferId>/<index>/get   Mac→phone chunk, same framing in the reply
//   POST /v2/file/<transferId>/status        sealed {"have":[…]} for resume
// Chunk AAD: devswitch/file/v1/<deviceId>/<transferId>/<index>/<total>/<final 0|1>.
@MainActor final class FileChannel {
    nonisolated static let chunkSize = 256 * 1024
    nonisolated static let maxSize: Int64 = 2 * 1024 * 1024 * 1024
    // Mutated only on the main actor; the file queue reads just the immutable url and the verified sha256.
    private final class Transfer: @unchecked Sendable {
        let id: String; let incoming: Bool; let name: String; let size: Int64; let total: Int; var sha256: String
        let url: URL // .part file for incoming, the source file for outgoing
        var handle: FileHandle?
        var have: Set<Int> = []
        var expires = Date().addingTimeInterval(600)
        var finished = false
        init(id: String, incoming: Bool, name: String, size: Int64, sha256: String, url: URL) {
            self.id = id; self.incoming = incoming; self.name = name; self.size = size; self.sha256 = sha256; self.url = url
            total = max(1, Int((size + Int64(FileChannel.chunkSize) - 1) / Int64(FileChannel.chunkSize)))
        }
    }
    private unowned let controller: Controller
    private var active: Transfer?
    private let queue = DispatchQueue(label: "dev.notsg.devswitch.files")
    private var busy: Bool { active.map { !$0.finished && $0.expires > Date() } ?? false }

    init(controller: Controller) { self.controller = controller }

    /// Offers a Mac file to the phone; the fileOffer command is queued once its SHA-256 is known.
    func offerToPhone(file: URL) throws -> String {
        guard controller.phone != nil else { throw AppError.message("Pair a phone first.") }
        guard !busy else { throw AppError.message("Another transfer is in progress.") }
        let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard size >= 0, size <= Self.maxSize else { throw AppError.message("Files up to 2 GB can be sent.") }
        sweep()
        let transfer = Transfer(id: UUID().uuidString.lowercased(), incoming: false, name: file.lastPathComponent, size: size, sha256: "", url: file)
        active = transfer
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        queue.async {
            let sha256 = try? Self.sha256(of: file)
            Task { @MainActor in
                guard self.active === transfer else { return }
                guard let sha256 else { self.active = nil; NSLog("DevSwitch file %@ unreadable", transfer.id); return }
                transfer.sha256 = sha256
                self.controller.enqueue(OutgoingCommand("fileOffer", ["transferId": .string(transfer.id), "name": .string(transfer.name),
                    "size": .number(Double(size)), "mime": .string(mime), "sha256": .string(sha256), "chunkSize": .number(Double(Self.chunkSize))]))
            }
        }
        return transfer.id
    }

    /// Accepts a phone→Mac offer: prepares ~/Downloads/.<transferId>.part and tells the phone to start.
    func accept(offer: FileOfferEvent) {
        guard !busy, controller.phone != nil, offer.size <= Self.maxSize, offer.chunkSize == Self.chunkSize,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            controller.enqueue(OutgoingCommand("fileDecline", ["transferId": .string(offer.transferId)])); return
        }
        sweep()
        let part = downloads.appendingPathComponent(".\(offer.transferId).part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil), let handle = try? FileHandle(forWritingTo: part) else {
            controller.enqueue(OutgoingCommand("fileDecline", ["transferId": .string(offer.transferId)])); return
        }
        let transfer = Transfer(id: offer.transferId, incoming: true, name: offer.name, size: offer.size, sha256: offer.sha256, url: part)
        transfer.handle = handle
        active = transfer
        controller.enqueue(OutgoingCommand("fileAccept", ["transferId": .string(offer.transferId)]))
        controller.requestHotPolling(for: 30)
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst(3).map(String.init)
        guard let phone = controller.phone, let transfer = active, transfer.expires > Date(), parts.first == transfer.id else { return HTTPResponse(403) }
        do {
            if parts.count == 2, parts[1] == "status" {
                return try .json(200, SyncCrypto.seal(["have": transfer.have.sorted()], key: phone.key,
                                                      aad: "devswitch/file/v1/\(phone.id)/\(transfer.id)/status"))
            }
            guard parts.count == 2 || (parts.count == 3 && parts[2] == "get"), parts[1].count <= 5,
                  let index = Int(parts[1]), index >= 0, index < transfer.total else { return HTTPResponse(400) }
            guard transfer.incoming == (parts.count == 2) else { return HTTPResponse(403) }
            let aad = "devswitch/file/v1/\(phone.id)/\(transfer.id)/\(index)/\(transfer.total)/\(index == transfer.total - 1 ? 1 : 0)"
            let offset = UInt64(index) * UInt64(Self.chunkSize)
            let length = Int(min(Int64(Self.chunkSize), transfer.size - Int64(offset)))
            transfer.expires = Date().addingTimeInterval(600)
            controller.requestHotPolling(for: 30)
            if !transfer.incoming {
                let reader = try FileHandle(forReadingFrom: transfer.url)
                defer { try? reader.close() }
                try reader.seek(toOffset: offset)
                let plaintext = try reader.read(upToCount: length) ?? Data()
                guard plaintext.count == length else { throw AppError.message("Source file changed.") }
                if transfer.have.insert(index).inserted {
                    controller.message = transfer.have.count == transfer.total ? "Sent \(transfer.name) to your phone — Downloads › DevSwitch"
                        : "Sending \(transfer.name) to your phone… \(transfer.have.count * 100 / transfer.total)%"
                }
                if transfer.have.count == transfer.total { transfer.finished = true }
                var response = HTTPResponse(200, try SyncCrypto.sealBytes(plaintext, key: phone.key, aad: aad))
                response.contentType = "application/octet-stream"
                return response
            }
            let plaintext = try SyncCrypto.openBytes(request.body, key: phone.key, aad: aad)
            guard plaintext.count == length else { return HTTPResponse(400) }
            guard !transfer.have.contains(index), let handle = transfer.handle else { return HTTPResponse(200) }
            transfer.have.insert(index)
            queue.async {
                do { try handle.seek(toOffset: offset); try handle.write(contentsOf: plaintext) }
                catch { Task { @MainActor in self.fail(transfer) } }
            }
            if transfer.have.count == transfer.total { finish(transfer) }
            return HTTPResponse(200)
        } catch { return HTTPResponse(400) }
    }

    /// Drops an expired transfer and its partial file.
    func sweep() {
        guard let transfer = active, transfer.expires <= Date() else { return }
        if !transfer.finished { fail(transfer) }
        active = nil
    }

    func cancelOutgoing(_ id: String) {
        if let transfer = active, !transfer.incoming, transfer.id == id { fail(transfer) }
    }

    private func fail(_ transfer: Transfer) {
        guard !transfer.finished else { return }
        transfer.finished = true
        if active === transfer { active = nil }
        guard transfer.incoming, let handle = transfer.handle else { return }
        transfer.handle = nil
        queue.async { try? handle.close(); try? FileManager.default.removeItem(at: transfer.url) }
        NSLog("DevSwitch file %@ failed", transfer.id)
    }

    // Runs after every queued chunk write: verify, quarantine, then move into Downloads.
    private func finish(_ transfer: Transfer) {
        guard let handle = transfer.handle else { return }
        transfer.handle = nil
        let name = Self.safeName(transfer.name)
        queue.async {
            var destination: URL?
            do {
                try handle.close()
                guard try Self.sha256(of: transfer.url) == transfer.sha256 else { throw AppError.message("Checksum mismatch.") }
                var part = transfer.url
                var values = URLResourceValues()
                values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "DevSwitch",
                                               kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
                try part.setResourceValues(values)
                let target = Self.unusedURL(transfer.url.deletingLastPathComponent(), name)
                try FileManager.default.moveItem(at: transfer.url, to: target)
                destination = target
            } catch { try? FileManager.default.removeItem(at: transfer.url) }
            Task { @MainActor in
                transfer.finished = true
                // A saved transfer stays until it expires so the phone's resume check sees every chunk.
                if destination == nil, self.active === transfer { self.active = nil }
                NSLog("DevSwitch file %@ %@", transfer.id, destination == nil ? "failed" : "saved")
                if let destination {
                    self.controller.message = "Saved \(destination.lastPathComponent) to Downloads."
                    EventRouter.fileSaved(destination, from: self.controller.phone?.name)
                }
            }
        }
    }

    nonisolated static func safeName(_ raw: String) -> String {
        var name = displayString(raw, max: 200).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "..", with: "_")
        while name.hasPrefix(".") || name.hasPrefix(" ") { name.removeFirst() }
        return name.isEmpty ? "File from phone" : name
    }

    nonisolated private static func unusedURL(_ directory: URL, _ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var hasher = SHA256()
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

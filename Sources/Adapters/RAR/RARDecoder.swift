// Copyright 2026. Distributed under the BSD 3-Clause license in LICENSE.
import Foundation
import Cunrar

/// Single-pass, read-only UnRAR extraction. Original archive paths are never
/// used as filesystem destinations. RAR_TEST verifies checksums and supplies
/// bytes through callbacks without letting the decoder create files or links.
public enum RARDecoder {
    public struct Limits: Sendable {
        public var maxArchiveBytes: UInt64
        public var maxEntryBytes: UInt64
        public var maxExpandedBytes: UInt64
        public var maxDictionaryBytes: UInt64
        public var maxEntries: Int
        public init(maxArchiveBytes: UInt64 = 512 * 1024 * 1024,
                    maxEntryBytes: UInt64 = 64 * 1024 * 1024,
                    maxExpandedBytes: UInt64 = 2 * 1024 * 1024 * 1024,
                    maxDictionaryBytes: UInt64 = 64 * 1024 * 1024,
                    maxEntries: Int = 10_000) {
            self.maxArchiveBytes = maxArchiveBytes
            self.maxEntryBytes = maxEntryBytes
            self.maxExpandedBytes = maxExpandedBytes
            self.maxDictionaryBytes = maxDictionaryBytes
            self.maxEntries = maxEntries
        }
    }
    public struct Entry: Sendable {
        public let path: String
        public let fileURL: URL
        public let size: UInt64
    }
    public enum Failure: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? { switch self { case let .invalid(message): message } }
    }

    public static func extract(_ source: URL, to destination: URL, limits: Limits = .init()) throws -> [Entry] {
        try Task.checkCancellation()
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size >= 0, UInt64(size) <= limits.maxArchiveBytes else { throw Failure.invalid("The RAR archive exceeds the file size limit.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.invalid("The extraction destination already exists.") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        let context = CallbackContext(limits: limits)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(RAR_OM_EXTRACT)
        flags.Callback = callback
        flags.UserData = Int(bitPattern: pointer)
        let handle = source.path.utf8CString.withUnsafeBufferPointer { path in
            flags.ArcName = UnsafeMutablePointer(mutating: path.baseAddress)
            return RAROpenArchiveEx(&flags)
        }
        guard let handle else { throw context.failure ?? failure(code: Int32(flags.OpenResult)) }
        defer { RARCloseArchive(handle); context.close() }
        guard flags.OpenResult == 0 else { throw context.failure ?? failure(code: Int32(flags.OpenResult)) }
        guard flags.Flags & UInt32(ROADF_VOLUME) == 0 else { throw Failure.invalid("Multipart RAR archives aren't supported. Use a single-volume CBR.") }
        guard flags.Flags & UInt32(ROADF_ENCHEADERS) == 0 else { throw Failure.invalid("Password-protected RAR archives aren't supported yet.") }
        var results: [Entry] = []
        var paths = Set<String>()
        var declared: UInt64 = 0
        var entryCount = 0
        while true {
            try Task.checkCancellation()
            var header = RARHeaderDataEx()
            let status = RARReadHeaderEx(handle, &header)
            if status == ERAR_END_ARCHIVE { break }
            guard status == ERAR_SUCCESS else { throw context.failure ?? failure(code: status) }
            entryCount += 1
            guard entryCount <= limits.maxEntries else { throw Failure.invalid("The RAR archive contains too many entries.") }
            let path = name(of: header).replacingOccurrences(of: "\\", with: "/")
            guard safePath(path), paths.insert(path).inserted else { throw Failure.invalid("The RAR archive contains an unsafe or duplicate path.") }
            guard header.RedirType == 0, !(header.HostOS == 3 && header.FileAttr & 0xF000 == 0xA000) else {
                throw Failure.invalid("Links and redirected entries aren't supported in RAR archives.")
            }
            guard header.Flags & UInt32(RHDF_ENCRYPTED) == 0 else { throw Failure.invalid("Password-protected RAR archives aren't supported yet.") }
            guard header.Flags & UInt32(RHDF_SPLITBEFORE | RHDF_SPLITAFTER) == 0 else { throw Failure.invalid("Split RAR entries aren't supported.") }
            guard UInt64(header.DictSize) * 1024 <= limits.maxDictionaryBytes else { throw Failure.invalid("This RAR needs more decoder memory than the supported limit.") }
            let bytes = UInt64(header.UnpSizeHigh) << 32 | UInt64(header.UnpSize)
            guard bytes <= limits.maxEntryBytes, declared <= limits.maxExpandedBytes,
                  bytes <= limits.maxExpandedBytes - declared else { throw Failure.invalid("The RAR archive exceeds the expanded size limit.") }
            declared += bytes
            if header.Flags & UInt32(RHDF_DIRECTORY) != 0 {
                let status = RARProcessFile(handle, RAR_SKIP, nil, nil)
                guard status == ERAR_SUCCESS else { throw context.failure ?? failure(code: status) }
                continue
            }
            let file = destination.appendingPathComponent(String(format: "%05d.bin", results.count))
            try context.begin(file, declared: bytes)
            // Process every regular entry in archive order, retaining solid dictionaries.
            let processed = RARProcessFile(handle, RAR_TEST, nil, nil)
            guard processed == ERAR_SUCCESS else { throw context.failure ?? failure(code: processed) }
            try context.finish()
            results.append(Entry(path: path, fileURL: file, size: bytes))
        }
        complete = true
        return results
    }

    private static func name(of input: RARHeaderDataEx) -> String {
        var value = input.FileNameW
        let scalars: [UInt32] = withUnsafeBytes(of: &value) { bytes in
            var result: [UInt32] = []
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let scalar = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                if scalar == 0 { break }
                result.append(scalar)
            }
            return result
        }
        return String(decoding: scalars, as: UTF32.self)
    }
    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains(":") && !path.contains("\0") &&
            !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }
    private static func failure(code: Int32) -> Failure {
        switch code {
        case ERAR_MISSING_PASSWORD, ERAR_BAD_PASSWORD: return .invalid("Password-protected RAR archives aren't supported yet.")
        case ERAR_NO_MEMORY: return .invalid("This RAR exceeds the supported decoder memory limit.")
        case ERAR_UNKNOWN_FORMAT: return .invalid("This RAR uses an unsupported encoding.")
        default: return .invalid("The RAR archive is damaged, incomplete, or unreadable.")
        }
    }
    private static let callback: UNRARCALLBACK = { message, userData, p1, p2 in
        guard let pointer = UnsafeRawPointer(bitPattern: userData) else { return -1 }
        let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
        switch message {
        case UCM_PROCESSDATA.rawValue:
            do {
                try Task.checkCancellation()
                guard p2 >= 0, let bytes = UnsafeRawPointer(bitPattern: p1) else { throw Failure.invalid("Invalid RAR output buffer.") }
                try context.consume(bytes: bytes, count: p2)
                return 0
            } catch { context.failure = error; return -1 }
        case UCM_NEEDPASSWORD.rawValue, UCM_NEEDPASSWORDW.rawValue:
            context.failure = Failure.invalid("Password-protected RAR archives aren't supported yet.")
            return -1
        case UCM_CHANGEVOLUME.rawValue, UCM_CHANGEVOLUMEW.rawValue:
            context.failure = Failure.invalid("Multipart RAR archives aren't supported.")
            return -1
        default: return -1
        }
    }

    private final class CallbackContext {
        let limits: Limits
        var failure: Error?
        private var handle: FileHandle?
        private var entryBytes: UInt64 = 0
        private var expected: UInt64 = 0
        private var total: UInt64 = 0
        init(limits: Limits) { self.limits = limits }
        func begin(_ url: URL, declared: UInt64) throws {
            expected = declared
            entryBytes = 0
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: url)
        }
        func consume(bytes: UnsafeRawPointer, count: Int) throws {
            let size = UInt64(count)
            guard size <= expected - entryBytes, size <= limits.maxEntryBytes - entryBytes,
                  size <= limits.maxExpandedBytes - total else { throw Failure.invalid("A RAR entry expands beyond its allowed size.") }
            entryBytes += size
            total += size
            guard let handle else { throw Failure.invalid("Unexpected RAR output outside a file entry.") }
            // Write synchronously while UnRAR owns this buffer. Avoid copying a
            // decoder-sized block, and validate its length before wrapping it.
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: count, deallocator: .none)
            try handle.write(contentsOf: data)
        }
        func finish() throws {
            try handle?.close()
            handle = nil
            guard entryBytes == expected else { throw Failure.invalid("A RAR entry is incomplete.") }
        }
        func close() { try? handle?.close(); handle = nil }
    }
}

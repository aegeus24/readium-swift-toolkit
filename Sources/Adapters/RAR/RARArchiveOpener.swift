// Copyright 2026. Distributed under the BSD 3-Clause license in LICENSE.
import Foundation
import ReadiumShared

/// Optional local RAR/CBR support. Extracts once so solid archives do not have
/// to be decompressed from their beginning every time a reader requests a page.
public final class RARArchiveOpener: ArchiveOpener {
    private let limits: RARDecoder.Limits
    public init(limits: RARDecoder.Limits = .init()) { self.limits = limits }

    public func open(resource: Resource, format: Format) async -> Result<ContainerAsset, ArchiveOpenError> {
        guard format.conformsTo(.rar) else { return .failure(.formatNotSupported(format)) }
        guard let file = resource.sourceURL?.fileURL else {
            return .failure(.reading(.unsupportedOperation(RARDecoder.Failure.invalid("RAR support requires a local file."))))
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("readium-rar-" + UUID().uuidString)
        let limits = limits
        let task = Task.detached(priority: .userInitiated) {
            try RARDecoder.extract(file.url, to: destination, limits: limits)
        }
        do {
            let extracted = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            let container = try RARContainer(source: file, directory: destination, extracted: extracted)
            try Task.checkCancellation()
            return .success(ContainerAsset(container: container, format: format))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return .failure(.reading(ReadError.wrap(error) ?? .decoding(error)))
        }
    }
    public func sniffOpen(resource: Resource) async -> Result<ContainerAsset, ArchiveSniffOpenError> {
        switch await RARFormatSniffer().sniffBlob(resource) {
        case .success(let format?):
            return await open(resource: resource, format: format).mapError {
                switch $0 {
                case .formatNotSupported: return .formatNotRecognized
                case .reading(let error): return .reading(error)
                }
            }
        case .success(nil): return .failure(.formatNotRecognized)
        case .failure(let error): return .failure(.reading(error))
        }
    }
}

private final class RARLease {
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class RARContainer: Container {
    let sourceURL: AbsoluteURL?
    let entries: Set<AnyURL>
    private let files: [AnyURL: URL]
    private let lease: RARLease
    init(source: FileURL, directory: URL, extracted: [RARDecoder.Entry]) throws {
        sourceURL = source
        lease = RARLease(directory)
        var files: [AnyURL: URL] = [:]
        for entry in extracted {
            guard let url = AnyURL(path: entry.path) else { throw RARDecoder.Failure.invalid("Invalid RAR entry URL.") }
            guard files[url.normalized] == nil else { throw RARDecoder.Failure.invalid("Duplicate normalized RAR entry URL.") }
            files[url.normalized] = entry.fileURL
        }
        self.files = files
        entries = Set(files.keys)
    }
    subscript(url: any URLConvertible) -> Resource? {
        let key = url.anyURL.removingQuery().removingFragment().normalized
        guard let file = files[key], let fileURL = FileURL(url: file) else { return nil }
        return RARResource(file: fileURL, filename: key.lastPathSegment, lease: lease)
    }
}

private final class RARResource: Resource {
    private let resource: FileResource
    private let filename: String?
    private let lease: RARLease
    var sourceURL: AbsoluteURL? { resource.sourceURL }
    init(file: FileURL, filename: String?, lease: RARLease) {
        resource = FileResource(file: file)
        self.filename = filename
        self.lease = lease
    }
    func estimatedLength() async -> ReadResult<UInt64?> { await resource.estimatedLength() }
    func properties() async -> ReadResult<ResourceProperties> {
        .success(ResourceProperties { $0.filename = filename })
    }
    func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
        await resource.stream(range: range, consume: consume)
    }
}

import Foundation
import XCTest
import ReadiumShared
import ReadiumAdapterRAR

final class RARAdapterTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func fixture(_ name: String, _ ext: String = "cbr") throws -> URL {
        #if SWIFT_PACKAGE
        return try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        #else
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
        #endif
    }
    func testRAR5NormalAndSolidHaveIdenticalOutput() throws {
        let normal = try RARDecoder.extract(fixture("comic-rar5"), to: temporary.appendingPathComponent("normal"))
        let solid = try RARDecoder.extract(fixture("comic-rar5-solid"), to: temporary.appendingPathComponent("solid"))
        let first = try Dictionary(uniqueKeysWithValues: normal.map { ($0.path, try Data(contentsOf: $0.fileURL)) })
        let second = try Dictionary(uniqueKeysWithValues: solid.map { ($0.path, try Data(contentsOf: $0.fileURL)) })
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 4)
        XCTAssertTrue(first.keys.contains("pages/page10.png"))
        XCTAssertTrue(normal.allSatisfy { $0.fileURL.lastPathComponent.hasSuffix(".bin") })
    }
    func testRAR4UnicodeNamesAndPayloads() throws {
        let entries = try RARDecoder.extract(fixture("unicode-rar4", "rar"), to: temporary.appendingPathComponent("unicode"))
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.path.contains("サン") })
        for entry in entries { XCTAssertEqual(try Data(contentsOf: entry.fileURL).count, 15) }
    }
    func testEncryptedMultipartCorruptAndLinksAreRejectedWithoutOutput() throws {
        for (name, ext) in [("encrypted-rar5", "cbr"), ("multipart.part1", "rar"), ("badcrc", "rar"), ("links-rar4", "rar")] {
            let destination = temporary.appendingPathComponent(name)
            XCTAssertThrowsError(try RARDecoder.extract(fixture(name, ext), to: destination))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
    func testSizeAndEntryCountLimitsCleanUp() throws {
        let source = try fixture("comic-rar5-solid")
        for limits in [RARDecoder.Limits(maxEntryBytes: 16), .init(maxExpandedBytes: 500), .init(maxEntries: 1)] {
            let destination = temporary.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try RARDecoder.extract(source, to: destination, limits: limits))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
    func testTraversalPathIsRejectedBeforeCreatingItsFile() throws {
        let destination = temporary.appendingPathComponent("unsafe")
        do {
            _ = try RARDecoder.extract(fixture("unsafe-path"), to: destination)
            XCTFail("Expected an unsafe-path error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsafe"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("escape01.png").path))
    }
    func testCanceledDecoderDoesNotLeaveOutput() async throws {
        let source = try fixture("comic-rar5-solid")
        let destination = temporary.appendingPathComponent("cancel")
        let task = Task { try RARDecoder.extract(source, to: destination) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testReadiumArchiveOpenerServesPayloads() async throws {
        let source = try fixture("comic-rar5-solid")
        let file = try XCTUnwrap(FileURL(url: source))
        let opener = RARArchiveOpener()
        let asset = try await opener.sniffOpen(resource: FileResource(file: file)).get()
        XCTAssertTrue(asset.format.conformsTo(.rar))
        XCTAssertEqual(asset.container.entries.count, 4)
        let path = try XCTUnwrap(AnyURL(path: "pages/page2.png"))
        let resource = try XCTUnwrap(asset.container[path])
        let bytes = try await resource.read().get()
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }
}

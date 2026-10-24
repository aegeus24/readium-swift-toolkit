# UltraReader CBR support

CBR is implemented as the optional `ReadiumAdapterRAR` SwiftPM product, using source-built `mtgto/Unrar.swift` 0.5.4 and its bundled UnRAR 7.23 decoder. This adapter only reads/decompresses RAR; it does not create RAR archives.

## Integration

```swift
import ReadiumAdapterRAR
let archiveOpener = DefaultArchiveOpener(additionalArchiveOpeners: [RARArchiveOpener()])
```

Supply this opener to AssetRetriever with DefaultFormatSniffer and DefaultResourceFactory. RAR4 and RAR5 magic-byte detection is supported, and CBR hints reach the existing comic publication parser. The adapter accepts local files only. RARDecoder.extract is also available to importers that need persistent extracted pages.

## Extraction behavior

- A single archive pass processes every regular entry in archive order, preserving solid dictionaries. RAR_TEST verifies the entry checksum and supplies callbacks; no original archive path is passed to a filesystem extractor.
- Each payload is written to a generated flat filename, with a mapping back to its original Unicode path.
- Defaults limit compressed files to 512 MB, each entry to 64 MB, expanded output to 2 GB, dictionaries to 64 MB, and total entries to 10,000. Actual streamed byte counts are checked against both declared and configured limits.
- Cancellation is checked between entries and during output callbacks. Incomplete extraction is removed on failure/cancellation.
- Unsafe paths, duplicate normalized paths, links/redirections, encrypted files/headers, multipart archives, corruption, and unsupported encodings are rejected. Password entry is intentionally not implemented.
- The Readium container keeps extracted files alive through shared leases. Payload resources may outlive the container; temporary files are removed when the last lease is released.

## Verification

Tests/AdapterRARTests contains small original RAR5 normal/solid/encrypted comic fixtures and attributed upstream RAR4 Unicode/corruption/multipart/link fixtures. Tests cover exact normal-versus-solid output, Unicode names, payload access through ArchiveOpener, traversal rejection, output limits, cancellation, and cleanup. UltraReaderTests additionally covers full CBR import, natural image order, metadata, cover generation, saved progress, existing-catalog preservation, and parsing the CBR as a Readium publication.

The native app supports CBR using the same fixed-page reader, zoom, spreads, right-to-left controls, and center-spine curl as CBZ. Intentional double-spread metadata remains future work for both formats.

## Licensing

Retain both the Unrar.swift MIT license and the bundled UnRAR license and acknowledgements when distributing applications using this adapter. Fixture provenance and notices are in Tests/AdapterRARTests/Fixtures/NOTICES.txt. Only the fixture-generation workflow used the vendor's desktop RAR utility; the iOS app builds the decoder from source and never invokes a desktop executable.

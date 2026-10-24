# UltraReader CBR support

CBR is an explicit feature requirement for this fork. It is not implemented yet.

## Integration point

The toolkit already identifies `.cbr` hints and `.rar` signatures and the comic parser can consume a generic image container. The missing component is a RAR-backed `ArchiveOpener` and `Container`, supplied to `AssetRetriever` through `DefaultArchiveOpener(additionalArchiveOpeners:)`. Keep this as an optional adapter module so EPUB-only applications do not inherit a RAR decoder dependency.

The first groundwork patch fixes RAR signature sniffing. The previous implementation read at most eight bytes but required a byte count greater than eight, making magic-byte detection impossible. RAR4 uses a seven-byte prefix; RAR5 uses eight. The tests cover both versions and truncated/invalid signatures. This patch recognizes formats; it does not decode archives or enable CBR import.

## Decoder evaluation

Evaluate libarchive and an UnRAR wrapper for iOS device/simulator builds, source licensing/redistribution notices, modern RAR5 and solid archive coverage, bounded output, cancellation, Unicode filenames, and maintenance. No decoder is selected yet. Never invoke a desktop `unrar` executable from the iOS app.

## Acceptance checks

- RAR4 and RAR5 comics, including solid archives and nested folders.
- Natural page order, covers, ComicInfo metadata, right-to-left manga, and intentional double spreads.
- Bounded memory and disk use; actual output size checks and corruption detection.
- Reject unsafe paths, symlinks, multipart archives, and unsupported encryption with clear errors. Password entry may follow as a separate feature.
- Reuse the same publication/cursor pipeline as CBZ after decoding; preserve the existing ZIP and EPUB regressions.
- Include small redistributable original RAR fixtures with known source provenance and licenses.

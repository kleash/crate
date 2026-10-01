import CArchive
import Foundation

/// Split archives, 7-Zip style: the bytes of one archive cut into volumes "name.zip.001", "name.zip.002", …
/// (`cat name.zip.0* > name.zip` joins them back). `Archive.create` writes them; `list` reads them from any volume.
extension Archive {
    static let incompleteSplitArchive = ArchiveError.failed(
        "This split archive is incomplete — make sure all parts (.001, .002, …) are in the same folder.")

    /// The volume number in a split archive's file name: "name.zip.001" → 1; nil for other names.
    static func volumeNumber(_ url: URL) -> Int? {
        let ext = url.pathExtension
        guard ext.utf8.count >= 3, ext.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let number = Int(ext), number > 0 else { return nil }
        return number
    }

    /// Volume `number` of the split archive `file`: "name.zip" → "name.zip.001". Three digits, more past 999.
    static func volume(_ number: Int, of file: URL) -> URL {
        file.appendingPathExtension(String(format: "%03d", number))
    }

    /// The archive file a volume belongs to: "name.zip.001" → "name.zip"; any other file is itself.
    static func archiveFile(_ url: URL) -> URL {
        volumeNumber(url) == nil ? url : url.deletingPathExtension()
    }

    /// The files to read for `url`: itself, or for a volume of a split archive, all of that archive's volumes from
    /// .001 on. Throws `incompleteSplitArchive` when `url` isn't among them (one before it is missing) or one is cut
    /// short: every volume but the last is as big as the first, and the last no bigger.
    static func volumes(of url: URL) throws -> [URL] {
        guard let number = volumeNumber(url) else { return [url] }
        var volumes: [URL] = []
        var sizes: [Int64] = []
        while let size = fileSize(volume(volumes.count + 1, of: archiveFile(url))) {
            volumes.append(volume(volumes.count + 1, of: archiveFile(url)))
            sizes.append(size)
        }
        guard number <= volumes.count, sizes.dropLast().allSatisfy({ $0 == sizes[0] }),
              (1...max(1, sizes[0])).contains(sizes.last!) else { throw incompleteSplitArchive }
        return volumes
    }
}

/// A split archive's volumes, read by libarchive as one file through read, skip and seek callbacks.
/// libarchive's own multi-file reader (archive_read_open_filenames) can't be used: in 3.7.4 it fails to seek to
/// the last byte of a volume (a ZIP whose central directory starts there won't open) and crashed in free() on a
/// split .tar.gz.
final class VolumeReader {
    private let paths: [String]
    /// The offset just past each volume in the whole archive.
    private let ends: [Int64]
    private var position: Int64 = 0
    private var current = -1
    private var fd: Int32 = -1
    private static let blockSize = 65536
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)

    private init(_ volumes: [URL]) {
        paths = volumes.map(\.path)
        var end: Int64 = 0
        ends = volumes.map { end += Archive.fileSize($0) ?? 0; return end }
    }

    deinit {
        if fd >= 0 { close(fd) }
        buffer.deallocate()
    }

    /// Opens `r` on `volumes` (archive_read_open2). libarchive keeps the reader until it closes the archive,
    /// which releases it through the close callback.
    static func open(_ r: OpaquePointer, _ volumes: [URL]) -> Int32 {
        archive_read_set_seek_callback(r) { _, context, offset, whence in VolumeReader.from(context).seek(offset, whence) }
        return archive_read_open2(r, Unmanaged.passRetained(VolumeReader(volumes)).toOpaque(), nil,
                                  { _, context, buffer in VolumeReader.from(context).read(buffer!) },
                                  { _, context, request in VolumeReader.from(context).skip(request) },
                                  { _, context in Unmanaged<VolumeReader>.fromOpaque(context!).release(); return ARCHIVE_OK })
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> VolumeReader {
        Unmanaged<VolumeReader>.fromOpaque(context!).takeUnretainedValue()
    }

    /// The next block, from the volume holding `position`; 0 at the end, -1 when a volume can't be read.
    private func read(_ block: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        guard let index = ends.firstIndex(where: { $0 > position }) else { return 0 }
        if index != current {
            if fd >= 0 { close(fd) }
            fd = Darwin.open(paths[index], O_RDONLY | O_CLOEXEC)
            current = fd >= 0 ? index : -1
            guard fd >= 0 else { return -1 }
        }
        let start = index == 0 ? 0 : ends[index - 1]
        let count = pread(fd, buffer, Int(min(Int64(Self.blockSize), ends[index] - position)), off_t(position - start))
        guard count > 0 else { return -1 }  // shorter than when it was measured
        position += Int64(count)
        block.pointee = UnsafeRawPointer(buffer)
        return count
    }

    private func skip(_ request: Int64) -> Int64 {
        let count = min(max(request, 0), ends.last! - position)
        position += count
        return count
    }

    private func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        let target = (whence == SEEK_CUR ? position : whence == SEEK_END ? ends.last! : 0) + offset
        guard (0...ends.last!).contains(target) else { return Int64(ARCHIVE_FATAL) }
        position = target
        return target
    }
}

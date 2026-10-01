import CArchive
import Foundation

/// Archive operations on the system libarchive. Each call opens its own libarchive handles and keeps no
/// shared state, so calls may run on background queues, several at a time.
public enum Archive {
    /// Reads the table of contents. Opens every format libarchive reads (zip, tar and compressed tars, 7z,
    /// rar/rar5, iso, cpio, xar, …); a file no archive format claims but which is compressed (.gz, .bz2, .xz, …)
    /// lists as a single entry named after the file without its extension.
    /// Needs no passphrase: ZIP names are never encrypted, and 7z/RAR archives with encrypted names
    /// throw `unsupportedEncryption` because libarchive can't decrypt them at all.
    /// Any volume of a split archive ("name.zip.001", "name.zip.002", …) opens the whole archive; it is read-only.
    public static func list(_ url: URL) throws -> ArchiveListing {
        // An archive opened through a symlink: size, extraction and edits all concern the file it points to.
        let url = url.resolvingSymlinksInPath()
        let volumes = try self.volumes(of: url)
        do {
            return try list(volumes, split: volumeNumber(url) != nil)
        } catch ArchiveError.failed(let message) where volumeNumber(url) != nil && message != "Unrecognized archive format" {
            // A split archive that breaks off or jumps mid-way (even while libarchive is still detecting the
            // format) is missing a volume, or has one cut short. Volumes of something else keep their error.
            throw incompleteSplitArchive
        }
    }

    private static func list(_ volumes: [URL], split: Bool) throws -> ArchiveListing {
        let r = try openReader(volumes, passphrase: nil)
        defer { archive_read_free(r) }
        var entries: [ArchiveEntry] = []
        var entry: OpaquePointer?
        while try nextHeader(r, &entry) {
            let e = entry!
            let type = archive_entry_filetype(e)
            let modified = archive_entry_mtime_is_set(e) != 0
                ? Date(timeIntervalSince1970: Double(archive_entry_mtime(e)) + Double(archive_entry_mtime_nsec(e)) / 1e9)
                : nil
            var size = type == AE_IFREG && archive_entry_size_is_set(e) != 0 ? archive_entry_size(e) : 0
            // A single compressed file has no size in its header; gzip (unlike bzip2 and xz) records it at the end.
            if family(r) == ARCHIVE_FORMAT_RAW && archive_filter_code(r, 0) == ARCHIVE_FILTER_GZIP { size = gzipSize(volumes.last!) }
            entries.append(ArchiveEntry(
                path: path(of: e, in: r, url: volumes[0]),
                isDirectory: type == AE_IFDIR,
                isSymlink: type == AE_IFLNK,
                size: size,
                modified: modified,
                isEncrypted: archive_entry_is_encrypted(e) != 0))
        }
        let writable = WritableFormat(family: family(r), filter: archive_filter_code(r, 0))
        var name = writable?.displayName ?? describe(r)
        if split { name += volumes.count == 1 ? " (1 volume)" : " (\(volumes.count) volumes)" }
        return ArchiveListing(volumes: volumes, archiveEntries: entries, formatName: name, writableFormat: writable,
                              archiveSize: volumes.reduce(0) { $0 + (fileSize($1) ?? 0) })
    }

    /// Opens `volumes` (one file, or a split archive's volumes in order) for reading with every filter and format
    /// libarchive supports; a compressed file that no archive format claims opens in libarchive's "raw" format as
    /// one entry (see `path(of:in:url:)`).
    static func openReader(_ volumes: [URL], passphrase: String?) throws -> OpaquePointer {
        func reader(raw: Bool) -> OpaquePointer {
            let r = archive_read_new()!
            archive_read_support_filter_all(r)
            if raw { archive_read_support_format_raw(r) } else { archive_read_support_format_all(r) }
            if let passphrase { archive_read_add_passphrase(r, passphrase) }
            return r
        }
        func open(_ r: OpaquePointer) -> Int32 {
            volumes.count == 1 ? archive_read_open_filename(r, volumes[0].path, 65536) : VolumeReader.open(r, volumes)
        }
        let r = reader(raw: false)
        if open(r) == ARCHIVE_OK { return r }
        let error = message(r)
        archive_read_free(r)
        let single = reader(raw: true)
        if open(single) == ARCHIVE_OK, archive_filter_code(single, 0) != ARCHIVE_FILTER_NONE {
            return single
        }
        archive_read_free(single)
        throw ArchiveError.failed(error)
    }

    /// Moves to the next entry; false at the end of the archive.
    static func nextHeader(_ r: OpaquePointer, _ entry: inout OpaquePointer?) throws -> Bool {
        let rc = archive_read_next_header(r, &entry)
        if rc == ARCHIVE_EOF { return false }
        if rc == ARCHIVE_OK || rc == ARCHIVE_WARN { return true }
        // Unreadable headers mean encrypted names in 7z/RAR (ZIP never encrypts them).
        if archive_read_has_encrypted_entries(r) == 1 && family(r) != ARCHIVE_FORMAT_ZIP {
            throw ArchiveError.unsupportedEncryption(formatName(r))
        }
        throw ArchiveError.failed(message(r))
    }

    /// The error for a failed read of entry `e`'s data.
    static func dataError(_ r: OpaquePointer, _ e: OpaquePointer, passphrase: String?) -> ArchiveError {
        guard archive_entry_is_encrypted(e) != 0 else { return .failed(message(r)) }
        guard family(r) == ARCHIVE_FORMAT_ZIP else { return .unsupportedEncryption(formatName(r)) }
        return passphrase == nil ? .passphraseRequired : .wrongPassphrase
    }

    /// The entry's normalized path. In the raw format (a single compressed file) it is the file's name
    /// without its last extension: "notes.txt.gz" → "notes.txt" (and "notes.txt.gz.001" → "notes.txt").
    static func path(of e: OpaquePointer, in r: OpaquePointer, url: URL) -> String {
        if family(r) == ARCHIVE_FORMAT_RAW { return archiveFile(url).deletingPathExtension().lastPathComponent }
        let raw = archive_entry_pathname_utf8(e) ?? archive_entry_pathname(e)
        return raw.map { normalize(String(cString: $0)) } ?? ""
    }

    static func family(_ a: OpaquePointer) -> Int32 {
        archive_format(a) & ARCHIVE_FORMAT_BASE_MASK
    }

    static func formatName(_ r: OpaquePointer) -> String {
        archive_format_name(r).map { String(cString: $0) } ?? "Unknown"
    }

    /// libarchive's own name for a format WritableFormat doesn't cover, e.g. "RAR5" or "ISO9660 + gzip".
    static func describe(_ r: OpaquePointer) -> String {
        let format = formatName(r)
        guard archive_filter_code(r, 0) != ARCHIVE_FILTER_NONE else { return format }
        let filter = archive_filter_name(r, 0).map { String(cString: $0) } ?? "compressed"
        return family(r) == ARCHIVE_FORMAT_RAW ? filter.uppercased() : "\(format) + \(filter)"
    }

    static func message(_ a: OpaquePointer) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? "Unknown libarchive error"
    }

    static func check(_ rc: Int32, _ a: OpaquePointer) throws {
        guard rc == ARCHIVE_OK else { throw ArchiveError.failed(message(a)) }
    }

    /// The type bits (S_IFDIR, S_IFREG, …) of whatever is at `path`, not following a final symlink; nil if nothing is.
    static func fileType(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode & S_IFMT : nil
    }

    /// The size of the regular file at `url` (following symlinks); nil when there is none.
    static func fileSize(_ url: URL) -> Int64? {
        var st = stat()
        return stat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG ? Int64(st.st_size) : nil
    }

    /// `path` with every symlink in it resolved; nil (and errno set) when it doesn't exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The uncompressed size recorded in a gzip file's trailer (modulo 4 GiB), or 0 if it can't be read.
    static func gzipSize(_ url: URL) -> Int64 {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var size: UInt32 = 0
        guard lseek(fd, -4, SEEK_END) >= 0, read(fd, &size, 4) == 4 else { return 0 }
        return Int64(UInt32(littleEndian: size))
    }
}

extension WritableFormat {
    init?(family: Int32, filter: Int32) {
        switch (family, filter) {
        case (ARCHIVE_FORMAT_ZIP, ARCHIVE_FILTER_NONE): self = .zip
        case (ARCHIVE_FORMAT_7ZIP, ARCHIVE_FILTER_NONE): self = .sevenZip
        case (ARCHIVE_FORMAT_TAR, ARCHIVE_FILTER_NONE): self = .tar
        case (ARCHIVE_FORMAT_TAR, ARCHIVE_FILTER_GZIP): self = .tarGz
        case (ARCHIVE_FORMAT_TAR, ARCHIVE_FILTER_BZIP2): self = .tarBz2
        case (ARCHIVE_FORMAT_TAR, ARCHIVE_FILTER_XZ): self = .tarXz
        default: return nil
        }
    }
}

/// Counts processed bytes and reports the fraction done to the caller's progress closure — only when it
/// moves by at least 0.1% — and turns a `false` reply into `ArchiveError.cancelled`.
struct Meter {
    let total: Int64
    private var done: Int64 = 0
    private var reported = -1

    init(total: Int64) { self.total = total }

    /// `fallback` is the fraction reported while the total is unknown (0).
    mutating func add(_ bytes: Int, _ progress: (Double) -> Bool, fallback: Double = 0) throws {
        done += Int64(bytes)
        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : min(1, fallback)
        let permille = Int(fraction * 1000)
        guard permille != reported else { return }
        reported = permille
        if !progress(fraction) { throw ArchiveError.cancelled }
    }
}

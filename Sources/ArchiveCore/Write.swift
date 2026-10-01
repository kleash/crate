import CArchive
import Foundation

extension Archive {
    /// Creates an archive at `url` from files and folders. Each item is stored under its own name (a folder with
    /// everything below it); symlinks are stored as links; paths are relative; no extended attributes, ACLs or
    /// file flags are stored.
    /// - passphrase: ZIP only, encrypts with AES-256; other formats throw `unsupportedEncryption`.
    /// - excludeJunk: skips .DS_Store, "._*" AppleDouble files and __MACOSX folders. Sockets, named pipes and
    ///   devices are always skipped. Two items with the same name are refused: only one could be extracted.
    /// - The archive is written to a hidden temporary file next to `url` and then renamed over it, so an error or
    ///   cancellation (progress returning false) leaves nothing behind.
    public static func create(_ items: [URL], at url: URL, format: WritableFormat, level: CompressionLevel = .normal,
                              passphrase: String? = nil, excludeJunk: Bool = true,
                              progress: (Double) -> Bool = { _ in true }) throws {
        try checkNames(items)
        var meter = Meter(total: diskSize(items))
        try writeArchive(url, format: format, level: level, passphrase: passphrase, replacing: false) { w in
            for item in items {
                try add(item, under: "", to: w, excludeJunk: excludeJunk, meter: &meter, progress: progress)
            }
        }
        _ = progress(1)
    }

    /// Rewrites `listing`'s archive with entries removed and files added. Everything is recompressed into a
    /// temporary file next to the archive, which then replaces it (FileManager.replaceItemAt); on error or
    /// cancellation the original is untouched.
    /// - removing: paths as in `listing.entries`; a folder takes everything below it. Removing or replacing the
    ///   target of a tar hard link that stays is refused, since the link holds no data of its own.
    /// - adding: files and folders to put into `folder` ("" = top level). An item whose path already exists
    ///   replaces it; for a folder, the old folder and everything in it. Junk files are skipped as in `create`.
    /// - passphrase: required when the archive has encrypted entries (ZIP only); everything is then re-encrypted
    ///   with it (AES-256).
    /// Throws `notEditable` unless `listing.writableFormat` is set.
    public static func rewrite(_ listing: ArchiveListing, removing: [String] = [], adding: [URL] = [], into folder: String = "",
                               passphrase: String? = nil, progress: (Double) -> Bool = { _ in true }) throws {
        guard let format = listing.writableFormat else { throw ArchiveError.notEditable }
        try checkNames(adding)
        var encryption: String?
        if listing.hasEncryptedEntries {
            guard format == .zip else { throw ArchiveError.unsupportedEncryption(format.displayName) }
            guard passphrase != nil else { throw ArchiveError.passphraseRequired }
            encryption = passphrase
        }
        let folder = normalize(folder)
        let replaced = Set(removing.map(normalize) + adding.map { folder.isEmpty ? $0.lastPathComponent : folder + "/" + $0.lastPathComponent })
        let kept = listing.entries.filter { !isInside(components($0.path), replaced) }
        var meter = Meter(total: kept.reduce(0) { $0 + $1.size } + diskSize(adding))

        let r = try openReader(listing.url, passphrase: passphrase)
        defer { archive_read_free(r) }
        try writeArchive(listing.url, format: format, level: .normal, passphrase: encryption, replacing: true) { w in
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var entry: OpaquePointer?
            while try nextHeader(r, &entry) {
                let e = entry!
                let path = self.path(of: e, in: r, url: listing.url)
                if isInside(components(path), replaced) { continue }
                // A tar hard link has no data of its own: without its target, the file would be lost.
                if let target = (archive_entry_hardlink_utf8(e) ?? archive_entry_hardlink(e)).map({ normalize(String(cString: $0)) }),
                   isInside(components(target), replaced) {
                    throw ArchiveError.failed("“\(path)” is a hard link to “\(target)”, so “\(target)” can't be removed or replaced.")
                }
                try meter.add(0, progress)
                guard archive_write_header(w, e) >= ARCHIVE_WARN else { throw ArchiveError.failed(message(w)) }
                while true {
                    let n = archive_read_data(r, &buffer, buffer.count)
                    if n == 0 { break }
                    guard n > 0 else { throw dataError(r, e, passphrase: passphrase) }
                    guard archive_write_data(w, buffer, n) >= 0 else { throw ArchiveError.failed(message(w)) }
                    try meter.add(n, progress)
                }
            }
            for item in adding {
                try add(item, under: folder, to: w, excludeJunk: true, meter: &meter, progress: progress)
            }
        }
        _ = progress(1)
    }

    /// Writes an archive through `body` into a hidden temporary file next to `url`, then moves it into place:
    /// with FileManager.replaceItemAt when `replacing` (keeps the original's Finder metadata), else by rename.
    /// On error or cancellation the temporary file is deleted and `url` is untouched.
    static func writeArchive(_ url: URL, format: WritableFormat, level: CompressionLevel, passphrase: String?,
                             replacing: Bool, body: (OpaquePointer) throws -> Void) throws {
        if passphrase != nil && format != .zip { throw ArchiveError.unsupportedEncryption(format.displayName) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).cratetmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw ArchiveError.failed("Can't create “\(url.lastPathComponent)”: \(String(cString: strerror(errno)))") }
        let w = archive_write_new()!
        var saved = false
        defer {
            // The writer never closes an fd it was given, so a failed archive can be dropped without finishing it.
            if !saved { archive_write_fail(w) }
            archive_write_free(w)
            close(fd)
            if !saved { unlink(temp.path) }
        }
        var options: [String]
        switch format {
        case .zip:
            archive_write_set_format_zip(w)
            options = ["zip:compression-level=\(level.value)", "zip:hdrcharset=UTF-8"]  // UTF-8 flag on non-ASCII names
        case .sevenZip:
            archive_write_set_format_7zip(w)
            options = ["7zip:compression-level=\(level.value)"]
        case .tar:
            archive_write_set_format_pax_restricted(w)
            options = []
        case .tarGz:
            archive_write_set_format_pax_restricted(w)
            archive_write_add_filter_gzip(w)
            options = ["gzip:compression-level=\(level.value)"]
        case .tarBz2:
            archive_write_set_format_pax_restricted(w)
            archive_write_add_filter_bzip2(w)
            options = ["bzip2:compression-level=\(level.value)"]
        case .tarXz:
            archive_write_set_format_pax_restricted(w)
            archive_write_add_filter_xz(w)
            options = ["xz:compression-level=\(level.value)"]
        }
        if let passphrase {
            options.append("zip:encryption=aes256")
            try check(archive_write_set_passphrase(w, passphrase), w)
        }
        if !options.isEmpty { try check(archive_write_set_options(w, options.joined(separator: ",")), w) }
        try check(archive_write_open_fd(w, fd), w)
        try body(w)
        try check(archive_write_close(w), w)
        if replacing {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else if rename(temp.path, url.path) != 0 {
            throw ArchiveError.failed("Can't save “\(url.lastPathComponent)”: \(String(cString: strerror(errno)))")
        }
        saved = true
    }

    /// Appends `item` (a file, link, or folder with everything below it) as "folder/<item name>/…".
    static func add(_ item: URL, under folder: String, to w: OpaquePointer, excludeJunk: Bool,
                    meter: inout Meter, progress: (Double) -> Bool) throws {
        let root = item.path
        let prefix = folder.isEmpty ? item.lastPathComponent : folder + "/" + item.lastPathComponent
        let disk = archive_read_disk_new()!
        defer { archive_read_free(disk) }
        // Replaces the macOS default (ARCHIVE_READDISK_MAC_COPYFILE, which stores metadata as "._" entries):
        // no extended attributes, ACLs or file flags.
        archive_read_disk_set_behavior(disk, ARCHIVE_READDISK_NO_XATTR | ARCHIVE_READDISK_NO_ACL | ARCHIVE_READDISK_NO_FFLAGS)
        try check(archive_read_disk_open(disk, root), disk)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var entry: OpaquePointer?
        while true {
            let rc = archive_read_next_header(disk, &entry)
            if rc == ARCHIVE_EOF { break }
            guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else { throw ArchiveError.failed(message(disk)) }
            let e = entry!
            // Entries are named by their path on disk: root, root/sub, root/sub/file, …
            let path = prefix + String(decoding: String(cString: archive_entry_pathname(e)).utf8.dropFirst(root.utf8.count), as: UTF8.self)
            let name = components(path).last ?? ""
            // Skipping a folder before descending skips its contents too. ".cratetmp" is an archive being written.
            if name.hasSuffix(".cratetmp") || (excludeJunk && (name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._"))) {
                continue
            }
            archive_read_disk_descend(disk)
            archive_entry_set_pathname_utf8(e, path)
            // Sockets, named pipes and devices are left out: ZIP can't store them, nor TAR a socket.
            let type = archive_entry_filetype(e)
            guard type == AE_IFREG || type == AE_IFDIR || type == AE_IFLNK else { continue }
            let isFile = type == AE_IFREG
            if !isFile { archive_entry_set_size(e, 0) }
            try meter.add(0, progress)
            guard archive_write_header(w, e) >= ARCHIVE_WARN else { throw ArchiveError.failed(message(w)) }
            guard isFile else { continue }
            while true {
                let n = archive_read_data(disk, &buffer, buffer.count)
                if n == 0 { break }
                guard n > 0 else { throw ArchiveError.failed(message(disk)) }
                guard archive_write_data(w, buffer, n) >= 0 else { throw ArchiveError.failed(message(w)) }
                try meter.add(n, progress)
            }
        }
    }

    /// Throws when two of `items` would be stored under the same name: extracting would keep only one of them.
    static func checkNames(_ items: [URL]) throws {
        var names = Set<String>()
        for item in items where !names.insert(item.lastPathComponent).inserted {
            throw ArchiveError.failed("Two of the items are named “\(item.lastPathComponent)”.")
        }
    }

    /// Total size of the regular files in and below `items`, for progress.
    static func diskSize(_ items: [URL]) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        func size(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.fileSize ?? 0)
        }
        var total: Int64 = 0
        for item in items {
            total += size(item)
            if let walker = FileManager.default.enumerator(at: item, includingPropertiesForKeys: Array(keys)) {
                for case let url as URL in walker { total += size(url) }
            }
        }
        return total
    }
}

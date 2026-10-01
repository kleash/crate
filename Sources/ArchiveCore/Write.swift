import CArchive
import Foundation

extension Archive {
    /// Creates an archive at `url` from files and folders. Each item is stored under its own name (a folder with
    /// everything below it); symlinks are stored as links; paths are relative; no extended attributes, ACLs or
    /// file flags are stored.
    /// - passphrase: ZIP only, encrypts with AES-256; other formats throw `unsupportedEncryption`.
    /// - excludeJunk: skips .DS_Store, "._*" AppleDouble files and __MACOSX folders. Sockets, named pipes and
    ///   devices are always skipped. Two items with the same name are refused: only one could be extracted.
    /// - volumeSize: splits the archive 7-Zip style into volumes of this many bytes (the last one smaller), named
    ///   url.001, url.002, … (url.1000 past 999). An archive that fits in one volume is saved as url. Pick `url`
    ///   with `uniqueURL`: existing files are replaced.
    /// - The archive is written to hidden temporary files next to `url` and then renamed over it, so an error or
    ///   cancellation (progress returning false) leaves nothing behind.
    /// - Returns: the files written: [url], or the volumes in order.
    @discardableResult
    public static func create(_ items: [URL], at url: URL, format: WritableFormat, level: CompressionLevel = .normal,
                              passphrase: String? = nil, excludeJunk: Bool = true, volumeSize: Int64? = nil,
                              progress: (Double) -> Bool = { _ in true }) throws -> [URL] {
        precondition((volumeSize ?? 1) > 0, "volumeSize must be positive")
        try checkNames(items)
        var meter = Meter(total: diskSize(items))
        let files = try writeArchive(url, format: format, level: level, passphrase: passphrase, volumeSize: volumeSize,
                                     replacing: false) { w in
            for item in items {
                try add(item, under: "", to: w, excludeJunk: excludeJunk, meter: &meter, progress: progress)
            }
        }
        _ = progress(1)
        return files
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
    /// Throws `notEditable` unless `listing.isEditable` (a format Crate writes, not split into volumes).
    public static func rewrite(_ listing: ArchiveListing, removing: [String] = [], adding: [URL] = [], into folder: String = "",
                               passphrase: String? = nil, progress: (Double) -> Bool = { _ in true }) throws {
        guard let format = listing.writableFormat, listing.isEditable else { throw ArchiveError.notEditable }
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

        let r = try openReader(listing.volumes, passphrase: passphrase)
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

    /// Writes an archive through `body` into hidden temporary files next to `url` (see `Output`), then moves it
    /// into place: with FileManager.replaceItemAt when `replacing` (keeps the original's Finder metadata), else by
    /// rename. On error or cancellation the temporary files are deleted and `url` is untouched.
    /// Returns the files written: [url], or the volumes when `volumeSize` split the archive.
    @discardableResult
    static func writeArchive(_ url: URL, format: WritableFormat, level: CompressionLevel, passphrase: String?,
                             volumeSize: Int64? = nil, replacing: Bool, body: (OpaquePointer) throws -> Void) throws -> [URL] {
        if passphrase != nil && format != .zip { throw ArchiveError.unsupportedEncryption(format.displayName) }
        let output = try Output(url, volumeSize: volumeSize)
        let w = archive_write_new()!
        var saved = false
        defer {
            // Failed: drop the archive without finishing it, so nothing more is written, then delete what was.
            if !saved { archive_write_fail(w) }
            archive_write_free(w)
            if !saved { output.discard() }
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
        archive_write_set_bytes_in_last_block(w, 1)  // no padding after the archive's last byte
        try check(archive_write_open(w, Unmanaged.passUnretained(output).toOpaque(), nil, { _, context, buffer, length in
            Unmanaged<Output>.fromOpaque(context!).takeUnretainedValue().write(buffer!, length)
        }, nil), w)
        do {
            try body(w)
            try check(archive_write_close(w), w)
        } catch {
            // libarchive only learns that a write failed; Output knows why (a full disk, …).
            if let failure = output.failure { throw ArchiveError.failed(failure) }
            throw error
        }
        let files = try output.save(replacing: replacing)
        saved = true
        return files
    }

    /// Where `writeArchive` puts libarchive's output: a hidden temporary file next to `url`, and with `volumeSize` a
    /// new one each time the current one holds that many bytes. `save` moves them into place.
    final class Output {
        private let url: URL
        private let volumeSize: Int64
        private let id = UUID().uuidString
        private var temps: [URL] = []
        private var fd: Int32 = -1
        /// Bytes the current file can still take.
        private var room: Int64 = 0
        /// Why a write failed.
        private(set) var failure: String?

        /// Creates the first file at once, so that a folder that can't be written to fails before any work.
        init(_ url: URL, volumeSize: Int64?) throws {
            self.url = url
            self.volumeSize = volumeSize ?? .max
            if let error = next() { throw ArchiveError.failed(error) }
        }

        /// Starts the next temporary file; returns why it couldn't be created.
        private func next() -> String? {
            if fd >= 0 { close(fd) }
            // ".cratetmp": `add` never puts an archive being written into an archive.
            let suffix = temps.isEmpty ? "" : ".\(temps.count + 1)"
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(id)\(suffix).cratetmp")
            fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
            guard fd >= 0 else { return "Can't create “\(url.lastPathComponent)”: \(String(cString: strerror(errno)))" }
            temps.append(temp)
            room = volumeSize
            return nil
        }

        /// libarchive's write callback: all `count` bytes, or -1.
        func write(_ bytes: UnsafeRawPointer, _ count: Int) -> Int {
            var done = 0
            while done < count {
                if room == 0, let error = next() {
                    failure = error
                    return -1
                }
                let n = Darwin.write(fd, bytes + done, Int(min(Int64(count - done), room)))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    failure = "Can't write “\(url.lastPathComponent)”: \(String(cString: strerror(errno)))"
                    return -1
                }
                done += n
                room -= Int64(n)
            }
            return count
        }

        /// Moves the files into place: one as `url`, several as url.001, url.002, … Returns where they went.
        func save(replacing: Bool) throws -> [URL] {
            close(fd)
            fd = -1
            if replacing {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temps[0])
                return [url]
            }
            let files = temps.count == 1 ? [url] : temps.indices.map { Archive.volume($0 + 1, of: url) }
            for (index, temp) in temps.enumerated() {
                guard rename(temp.path, files[index].path) == 0 else {
                    let error = String(cString: strerror(errno))
                    files[..<index].forEach { unlink($0.path) }
                    throw ArchiveError.failed("Can't save “\(files[index].lastPathComponent)”: \(error)")
                }
            }
            return files
        }

        /// Deletes the temporary files.
        func discard() {
            if fd >= 0 { close(fd) }
            fd = -1
            temps.forEach { unlink($0.path) }
        }
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

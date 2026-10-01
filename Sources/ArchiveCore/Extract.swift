import CArchive
import Foundation

extension Archive {
    /// Extracts `listing`'s archive into `destination`, creating it if needed.
    /// - paths: nil extracts everything with full paths. Otherwise only these entries (a folder brings everything
    ///   below it), placed relative to their deepest common parent folder: "docs/a.txt" lands at
    ///   destination/a.txt, "docs/img" at destination/img/….
    /// - Safety: nothing is written outside `destination`. A leading "/" is dropped, a ".." component throws
    ///   `unsafePath`, hard-link targets are confined the same way, and libarchive refuses to write through a
    ///   symlink (one in the way is replaced by a real folder).
    /// - overwrite: `.replace` replaces whatever is in the way (as in Finder, a folder where a file goes too);
    ///   `.skip` leaves anything already at an entry's destination untouched.
    /// - progress: fraction done (0…1); return false to cancel (throws `cancelled`). Entries extracted before an
    ///   error or cancel stay; the file being written is removed.
    public static func extract(_ listing: ArchiveListing, paths: [String]? = nil, to destination: URL,
                               passphrase: String? = nil, overwrite: OverwritePolicy = .replace,
                               progress: (Double) -> Bool = { _ in true }) throws {
        let selection = Selection(paths)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Resolve symlinks once: libarchive rejects any symlink along the (absolute) paths we give it.
        guard let root = realPath(destination.path) else {
            throw ArchiveError.failed("Can't open “\(destination.path)”: \(String(cString: strerror(errno)))")
        }
        let prefix = root == "/" ? "" : root
        var meter = Meter(total: listing.entries.reduce(0) { selection.relativePath($1.path) == nil ? $0 : $0 + $1.size })

        let r = try openReader(listing.volumes, passphrase: passphrase)
        defer { archive_read_free(r) }
        let disk = withUmaskLock { archive_write_disk_new()! }
        defer { archive_write_free(disk) }
        // No ARCHIVE_EXTRACT_SAFE_WRITES: UNLINK already removes an existing file before a new one is written,
        // and with SAFE_WRITES a folder entry landing on an existing file leaves a file there (libarchive 3.7.4).
        archive_write_disk_set_options(disk, ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT
            | ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_UNLINK)
        var entry: OpaquePointer?
        while try nextHeader(r, &entry) {
            let e = entry!
            let path = self.path(of: e, in: r, url: listing.url)
            guard !path.isEmpty, let relative = selection.relativePath(path) else { continue }
            guard !components(path).contains("..") else { throw ArchiveError.unsafePath(path) }
            let target = prefix + "/" + relative
            if overwrite == .skip && fileType(target) != nil { continue }
            if let link = archive_entry_hardlink_utf8(e) ?? archive_entry_hardlink(e) {
                let linkPath = normalize(String(cString: link))
                guard !components(linkPath).contains("..") else { throw ArchiveError.unsafePath(linkPath) }
                guard let linkRelative = selection.relativePath(linkPath) else {
                    throw ArchiveError.failed("“\(path)” is a hard link to “\(linkPath)”, which isn't being extracted.")
                }
                archive_entry_set_hardlink_utf8(e, prefix + "/" + linkRelative)
            }
            archive_entry_set_pathname_utf8(e, target)
            // A folder stored without owner rwx (Python's tarfile writes 0644) couldn't be opened or deleted.
            if archive_entry_filetype(e) == AE_IFDIR { archive_entry_set_perm(e, archive_entry_perm(e) | 0o700) }
            // Read the first block before touching the disk: a missing or wrong passphrase (or encryption
            // libarchive can't decrypt) fails here and leaves whatever is at `target` as it was.
            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            var rc = archive_read_data_block(r, &buffer, &size, &offset)
            guard rc == ARCHIVE_OK || rc == ARCHIVE_EOF else { throw dataError(r, e, passphrase: passphrase) }
            try meter.add(0, progress)
            // Replacing, as in Finder, swaps a folder in the way of a file for the file (libarchive only removes
            // empty folders). Not when a symlink is on the way there: that folder could be outside the destination.
            if overwrite == .replace, archive_entry_filetype(e) != AE_IFDIR, fileType(target) == S_IFDIR,
               realPath(target) == target {
                try FileManager.default.removeItem(atPath: target)
            }
            guard withUmaskLock({ archive_write_header(disk, e) }) >= ARCHIVE_WARN else {
                throw ArchiveError.failed("\(path): \(message(disk))")
            }
            do {
                while rc == ARCHIVE_OK {
                    guard archive_write_data_block(disk, buffer, size, offset) >= 0 else {
                        throw ArchiveError.failed(message(disk))
                    }
                    let position = Double(archive_filter_bytes(r, -1)) / Double(max(listing.archiveSize, 1))
                    try meter.add(size, progress, fallback: position)
                    rc = archive_read_data_block(r, &buffer, &size, &offset)
                }
                guard rc == ARCHIVE_EOF else { throw dataError(r, e, passphrase: passphrase) }
            } catch {
                // Freeing the writer would pad the file to its full size; finish it and delete it instead.
                archive_write_finish_entry(disk)
                unlink(target)
                throw error
            }
            guard archive_write_finish_entry(disk) >= ARCHIVE_WARN else { throw ArchiveError.failed(message(disk)) }
        }
        guard archive_write_close(disk) >= ARCHIVE_WARN else { throw ArchiveError.failed(message(disk)) }
        _ = progress(1)
    }

    /// The entries (paths as in `listing.entries`) that `extract` with the same `paths` would overwrite in
    /// `destination`: anything existing where a file or link goes, and non-folders where a folder goes.
    public static func conflicts(_ listing: ArchiveListing, paths: [String]? = nil, in destination: URL) -> [String] {
        let selection = Selection(paths)
        return listing.entries.compactMap { entry in
            guard let relative = selection.relativePath(entry.path),
                  let type = fileType(destination.path + "/" + relative) else { return nil }
            return entry.isDirectory && type == S_IFDIR ? nil : entry.path
        }
    }

    /// Where "Extract Here" should extract everything so that `folder` gains exactly one new item: `folder` itself
    /// when the archive holds a single top-level item that doesn't exist there yet, otherwise a new folder named
    /// after the archive ("demo.tar.gz" or "demo.zip.001" → "demo", or "demo 2", "demo 3", … when taken).
    /// Returns the `destination` to pass to `extract` and the `item` the extraction creates.
    public static func smartExtractDestination(_ listing: ArchiveListing, in folder: URL) -> (destination: URL, item: URL) {
        let topLevel = Set(listing.entries.compactMap { components($0.path).first })
        if topLevel.count == 1, let top = topLevel.first, fileType(folder.appendingPathComponent(top).path) == nil {
            return (folder, folder.appendingPathComponent(top))
        }
        var stem = archiveFile(listing.url).deletingPathExtension()
        if stem.pathExtension.lowercased() == "tar" { stem.deletePathExtension() }
        let item = uniqueURL(in: folder, name: stem.lastPathComponent)
        return (item, item)
    }

    /// `folder/name.ext`, or the first of "name 2.ext", "name 3.ext", … that doesn't exist yet, nor as a volume of a
    /// split archive ("name.ext.001", or a leftover "name.ext.003" that a new set would take in as its own).
    /// `ext` has no leading dot ("tar.gz"); pass "" for a folder.
    public static func uniqueURL(in folder: URL, name: String, extension ext: String = "") -> URL {
        // The names that volumes in `folder` belong to ("Archive.zip.003" → "archive.zip"), lowercased because Mac
        // file systems normally ignore case: "archive.zip.003" would be read as a volume of "Archive.zip" too.
        let split = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { volumeNumber(folder.appendingPathComponent($0, isDirectory: false)) != nil }
            .map { ($0 as NSString).deletingPathExtension.lowercased() })
        var n = 1
        while true {
            let candidate = folder.appendingPathComponent((n == 1 ? name : "\(name) \(n)") + (ext.isEmpty ? "" : "." + ext))
            if fileType(candidate.path) == nil && !split.contains(candidate.lastPathComponent.lowercased()) { return candidate }
            n += 1
        }
    }

    /// libarchive's disk writer reads the process umask with `umask(umask(0))` in archive_write_disk_new and in
    /// every archive_write_header. Two extractions doing that at once could leave the umask at 0, so those
    /// calls are serialized.
    private static let umaskLock = NSLock()

    static func withUmaskLock<T>(_ body: () -> T) -> T {
        umaskLock.lock()
        defer { umaskLock.unlock() }
        return body()
    }
}

/// The entries an extraction writes, and where they go below the destination.
struct Selection {
    private let paths: Set<String>?
    /// How many leading components to drop: those of the selected paths' deepest common parent folder.
    private let depth: Int

    init(_ list: [String]?) {
        guard let list else {
            paths = nil
            depth = 0
            return
        }
        let parents = list.map { components($0).dropLast() }
        var common = Array(parents.first ?? [])
        for parent in parents.dropFirst() {
            common = zip(common, parent).prefix { $0 == $1 }.map { $0.0 }
        }
        paths = Set(list.map(normalize))
        depth = common.count
    }

    /// `path` relative to the destination, or nil when it isn't selected.
    func relativePath(_ path: String) -> String? {
        let parts = components(path)
        if let paths, !isInside(parts, paths) { return nil }
        return parts.dropFirst(depth).joined(separator: "/")
    }
}

/// True when the path made of `parts`, or one of its parent folders, is in `paths`.
func isInside(_ parts: [String], _ paths: Set<String>) -> Bool {
    var prefix = ""
    for part in parts {
        prefix = prefix.isEmpty ? part : prefix + "/" + part
        if paths.contains(prefix) { return true }
    }
    return false
}

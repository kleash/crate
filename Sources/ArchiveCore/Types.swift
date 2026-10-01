import Foundation

/// A file, folder or link inside an archive.
public struct ArchiveEntry: Hashable, Sendable {
    /// Path inside the archive, normalized: "folder/sub/file.txt" (no leading "/" or "./", no trailing "/").
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// Uncompressed size in bytes; 0 for folders, links and sizes the format doesn't record.
    public let size: Int64
    public let modified: Date?
    public let isEncrypted: Bool

    /// The last path component.
    public var name: String { components(path).last ?? "" }
    /// The containing folder's path; "" at the top level.
    public var parent: String { components(path).dropLast().joined(separator: "/") }
}

/// What `Archive.list(_:)` found in an archive.
public struct ArchiveListing: Sendable {
    public let url: URL
    /// Every entry in archive order, plus the folders that are only implied by the paths below them.
    /// Each path appears once; when the archive repeats one, the last copy wins (as it would on extraction).
    public let entries: [ArchiveEntry]
    /// Short name for display: "ZIP", "TAR.GZ", "7-Zip", "RAR5", "ISO9660", …
    public let formatName: String
    /// The format `Archive.rewrite` writes back; nil for read-only formats (RAR, ISO, single-file .gz, …).
    public let writableFormat: WritableFormat?
    public let hasEncryptedEntries: Bool
    /// Size of the archive file in bytes.
    public let archiveSize: Int64
    private let childrenByFolder: [String: [ArchiveEntry]]

    public var isEditable: Bool { writableFormat != nil }

    /// The entries directly inside `folder` ("" for the top level), in archive order.
    public func children(of folder: String) -> [ArchiveEntry] {
        childrenByFolder[normalize(folder)] ?? []
    }

    init(url: URL, archiveEntries: [ArchiveEntry], formatName: String, writableFormat: WritableFormat?, archiveSize: Int64) {
        var entries: [ArchiveEntry] = []
        var index: [String: Int] = [:]
        for entry in archiveEntries where !entry.path.isEmpty {
            var folder = ""
            for part in components(entry.path).dropLast() {
                folder = folder.isEmpty ? part : folder + "/" + part
                if index[folder] == nil {
                    index[folder] = entries.count
                    entries.append(ArchiveEntry(path: folder, isDirectory: true, isSymlink: false, size: 0, modified: nil, isEncrypted: false))
                }
            }
            if let i = index[entry.path] {
                entries[i] = entry
            } else {
                index[entry.path] = entries.count
                entries.append(entry)
            }
        }
        self.url = url
        self.entries = entries
        self.formatName = formatName
        self.writableFormat = writableFormat
        self.hasEncryptedEntries = entries.contains { $0.isEncrypted }
        self.archiveSize = archiveSize
        self.childrenByFolder = Dictionary(grouping: entries, by: \.parent)
    }
}

/// The formats Crate can create and edit.
public enum WritableFormat: CaseIterable, Sendable {
    case zip, sevenZip, tar, tarGz, tarBz2, tarXz

    /// File name extension without the leading dot, e.g. "tar.gz".
    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        }
    }

    public var displayName: String {
        self == .sevenZip ? "7-Zip" : fileExtension.uppercased()
    }
}

public enum CompressionLevel: CaseIterable, Sendable {
    case fast, normal, best

    /// The 0–9 level passed to libarchive's zip, 7zip, gzip, bzip2 and xz writers.
    var value: Int {
        switch self {
        case .fast: return 1
        case .normal: return 6
        case .best: return 9
        }
    }
}

/// What extraction does when something already exists at an entry's destination.
public enum OverwritePolicy: Sendable {
    case replace, skip
}

public enum ArchiveError: Error, LocalizedError, Equatable {
    case passphraseRequired
    case wrongPassphrase
    /// The format's encryption isn't supported (libarchive can't decrypt 7-Zip or RAR, and only writes encrypted ZIP).
    case unsupportedEncryption(String)
    /// An entry would land outside the destination folder (its path contains "..").
    case unsafePath(String)
    case cancelled
    case notEditable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .passphraseRequired: return "This archive is encrypted. Enter its password to continue."
        case .wrongPassphrase: return "The password is incorrect."
        case .unsupportedEncryption(let format): return "Crate doesn't support encrypted \(format) archives."
        case .unsafePath(let path): return "Extraction stopped because the archive contains an unsafe path: “\(path)”."
        case .cancelled: return "The operation was cancelled."
        case .notEditable: return "Archives in this format can't be changed. Only ZIP, 7-Zip and TAR archives can be edited."
        case .failed(let message): return message
        }
    }
}

/// "/"-separated path components without empty and "." ones. Splits on the "/" byte, so a combining
/// character after a slash can't hide a separator (Swift's Character-based split would miss it).
func components(_ path: String) -> [String] {
    path.utf8.split(separator: UInt8(ascii: "/")).compactMap { bytes in
        let part = String(decoding: bytes, as: UTF8.self)
        return part == "." ? nil : part
    }
}

/// "./a//b/" → "a/b", "/etc/x" → "etc/x". ".." components are kept; extraction rejects them.
func normalize(_ path: String) -> String {
    components(path).joined(separator: "/")
}

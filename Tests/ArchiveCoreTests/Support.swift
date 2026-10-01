import CArchive
import Foundation
@testable import ArchiveCore

/// A temporary folder for one test, deleted when the test's suite instance goes away.
final class Scratch {
    let url: URL

    init(under parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appendingPathComponent("crate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    subscript(_ path: String) -> URL { url.appendingPathComponent(path) }
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func writeRandom(bytes count: Int, to url: URL) throws {
    var bytes = [UInt8](repeating: 0, count: count)
    arc4random_buf(&bytes, count)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}

func read(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

/// Whether anything (even a dangling symlink) is at `url`.
func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
}

/// tree/ with nested folders, an empty folder, an empty file, a Unicode name and a symlink.
@discardableResult
func makeTree(in folder: URL) throws -> URL {
    let tree = folder.appendingPathComponent("tree")
    try write("alpha\n", to: tree.appendingPathComponent("a.txt"))
    try write("bravo\n", to: tree.appendingPathComponent("sub/b.txt"))
    try write("charlie\n", to: tree.appendingPathComponent("sub/deeper/c.txt"))
    try write("unicode\n", to: tree.appendingPathComponent("café 日本 😀.txt"))
    try write("", to: tree.appendingPathComponent("sub/zero.txt"))
    try FileManager.default.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "a.txt")
    return tree
}

/// Everything below `folder` as relative path → "dir", "file:<contents>" or "link:<target>".
func snapshot(_ folder: URL) -> [String: String] {
    let fm = FileManager.default
    var result: [String: String] = [:]
    for case let relative as String in fm.enumerator(atPath: folder.path) ?? FileManager.DirectoryEnumerator() {
        let path = folder.appendingPathComponent(relative).path
        switch try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType {
        case .typeDirectory?: result[relative] = "dir"
        case .typeSymbolicLink?: result[relative] = "link:" + ((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?")
        default: result[relative] = "file:" + (read(URL(fileURLWithPath: path)) ?? "?")
        }
    }
    return result
}

/// Names of everything in `folder` (not recursive), hidden files included.
func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

/// Runs a command-line tool and returns its standard output; throws on a non-zero exit.
@discardableResult
func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ArchiveError.failed("\(tool) \(arguments) exited with \(process.terminationStatus)")
    }
    return String(decoding: data, as: UTF8.self)
}

/// An entry for `craftTar`, with paths and link targets written exactly as given.
enum Crafted {
    case file(String, String)
    case directory(String, perm: mode_t = 0o755)
    case symlink(String, String)
    /// Path, link target, and data carried by the link entry (pax allows that).
    case hardlink(String, String, String)
}

/// Writes a pax tar holding exactly `entries`; libarchive's writer doesn't sanitize paths.
func craftTar(_ url: URL, _ entries: [Crafted]) throws {
    let w = archive_write_new()!
    defer { archive_write_free(w) }
    archive_write_set_format_pax_restricted(w)
    guard archive_write_open_filename(w, url.path) == ARCHIVE_OK else { throw ArchiveError.failed("can't create \(url.path)") }
    for item in entries {
        let e = archive_entry_new()!
        defer { archive_entry_free(e) }
        archive_entry_set_mtime(e, 1_700_000_000, 0)
        var data = ""
        switch item {
        case .file(let path, let text):
            archive_entry_set_pathname_utf8(e, path)
            archive_entry_set_filetype(e, UInt32(AE_IFREG))
            archive_entry_set_perm(e, 0o644)
            data = text
        case .directory(let path, let perm):
            archive_entry_set_pathname_utf8(e, path)
            archive_entry_set_filetype(e, UInt32(AE_IFDIR))
            archive_entry_set_perm(e, perm)
        case .symlink(let path, let target):
            archive_entry_set_pathname_utf8(e, path)
            archive_entry_set_filetype(e, UInt32(AE_IFLNK))
            archive_entry_set_perm(e, 0o755)
            archive_entry_set_symlink_utf8(e, target)
        case .hardlink(let path, let target, let text):
            archive_entry_set_pathname_utf8(e, path)
            archive_entry_set_filetype(e, UInt32(AE_IFREG))
            archive_entry_set_perm(e, 0o644)
            archive_entry_set_hardlink_utf8(e, target)
            data = text
        }
        archive_entry_set_size(e, Int64(data.utf8.count))
        guard archive_write_header(w, e) >= ARCHIVE_WARN else { throw ArchiveError.failed("can't write \(item)") }
        if !data.isEmpty { _ = data.withCString { archive_write_data(w, $0, data.utf8.count) } }
    }
    guard archive_write_close(w) == ARCHIVE_OK else { throw ArchiveError.failed("can't close \(url.path)") }
}

/// The archive file's bytes after decompression (the tar inside a .tar.gz, …), read with libarchive's raw
/// format, which unlike the tar and zip readers doesn't hide "._" AppleDouble members.
func decompressedBytes(_ url: URL) throws -> Data {
    let r = archive_read_new()!
    defer { archive_read_free(r) }
    archive_read_support_filter_all(r)
    archive_read_support_format_raw(r)
    var entry: OpaquePointer?
    guard archive_read_open_filename(r, url.path, 65536) == ARCHIVE_OK,
          archive_read_next_header(r, &entry) == ARCHIVE_OK else { throw ArchiveError.failed("can't read \(url.path)") }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = archive_read_data(r, &buffer, buffer.count)
        guard n > 0 else { break }
        result.append(contentsOf: buffer[0..<n])
    }
    return result
}

/// The strength bytes (1 = AES-128, 2 = AES-192, 3 = AES-256) of every WinZip AES extra field
/// (id 0x9901, size 7: version, "AE", strength, method) in a zip file.
func zipAESStrengths(_ url: URL) throws -> [UInt8] {
    let bytes = [UInt8](try Data(contentsOf: url))
    var strengths: [UInt8] = []
    for i in 0..<max(0, bytes.count - 9)
    where bytes[i] == 0x01 && bytes[i + 1] == 0x99 && bytes[i + 2] == 7 && bytes[i + 3] == 0
        && bytes[i + 6] == UInt8(ascii: "A") && bytes[i + 7] == UInt8(ascii: "E") {
        strengths.append(bytes[i + 8])
    }
    return strengths
}

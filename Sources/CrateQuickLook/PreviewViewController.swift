import Cocoa
import Quartz
import CArchive
import os

// Entry point is NSExtensionMain (linker flag in Package.swift); this class is the
// NSExtensionPrincipalClass named in Resources/CrateQuickLook-Info.plist.
// Spike: shows the file name, its size and the first entries libarchive lists, and logs each
// step under subsystem com.sa.crate.quicklook (see `log show` in the Lane B handoff).
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let log = Logger(subsystem: "com.sa.crate.quicklook", category: "preview")
    private let scrollView = NSTextView.scrollableTextView()

    override func loadView() {
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view = scrollView
        log.log("loadView")
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        log.log("preparePreviewOfFile \(url.path, privacy: .public) size=\(size) main=\(Thread.isMainThread)")
        let (summary, lines) = Self.list(url.path)
        log.log("libarchive: \(summary, privacy: .public)")
        (scrollView.documentView as! NSTextView).string =
            "Crate Quick Look\n\(url.lastPathComponent): \(size) bytes\n\(summary)\n\n" + lines.joined(separator: "\n")
        handler(nil)
    }

    // Summary line plus up to `limit` "size<TAB>path" lines.
    private static func list(_ path: String, limit: Int = 50) -> (String, [String]) {
        guard let a = archive_read_new() else { return ("archive_read_new failed", []) }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        func error() -> String {
            "errno \(archive_errno(a)): " + (archive_error_string(a).map { String(cString: $0) } ?? "")
        }
        guard archive_read_open_filename(a, path, 65536) == ARCHIVE_OK else { return ("open failed, " + error(), []) }
        var lines: [String] = []
        var count = 0
        var entry: OpaquePointer?
        var r = archive_read_next_header(a, &entry)
        while r == ARCHIVE_OK || r == ARCHIVE_WARN, let e = entry {
            count += 1
            if lines.count < limit {
                let name = archive_entry_pathname_utf8(e).map { String(cString: $0) } ?? "?"
                lines.append("\(archive_entry_size(e))\t\(name)")
            }
            r = archive_read_next_header(a, &entry)
        }
        let format = archive_format_name(a).map { String(cString: $0) } ?? "?"
        return (r == ARCHIVE_EOF ? "\(format), \(count) entries" : "\(format), \(count) entries, then " + error(), lines)
    }
}

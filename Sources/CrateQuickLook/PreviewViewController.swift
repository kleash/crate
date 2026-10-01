import ArchiveCore
import Cocoa
import Quartz
import UniformTypeIdentifiers
import os

/// Quick Look preview of an archive (Space bar in Finder): the archive's icon, name and a summary line,
/// above its folder tree. The entry point is NSExtensionMain (linker flag in Package.swift); this class is
/// the NSExtensionPrincipalClass named in Resources/CrateQuickLook-Info.plist.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// At most this many entries go into the tree; a footer counts the rest.
    private static let cap = 10_000

    private let log = Logger(subsystem: "com.sa.crate", category: "quicklook")
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let tree = NSScrollView()
    private let outline = NSOutlineView()
    private var listing: ArchiveListing?
    /// Paths of the first `cap` entries when the archive has more; nil shows every entry.
    private var shown: Set<String>?
    private var roots: [Node] = []

    /// A row of the tree. NSOutlineView tracks items by identity, hence a class; children are made on first use.
    private final class Node {
        let entry: ArchiveEntry
        var children: [Node]?
        init(_ entry: ArchiveEntry) { self.entry = entry }
    }

    /// The root view, opaque in the table's background colour so the header reads in light and dark mode
    /// whatever Quick Look draws behind the extension.
    private final class Background: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    override func loadView() {
        // Quick Look sizes the view after viewDidAppear; autoresizing keeps the header on top and the tree filling the rest.
        let width: CGFloat = 800, height: CGFloat = 600
        view = Background(frame: NSRect(x: 0, y: 0, width: width, height: height))
        icon.frame = NSRect(x: 12, y: height - 58, width: 48, height: 48)
        icon.imageScaling = .scaleProportionallyUpOrDown  // file icons are 32 pt by default
        icon.autoresizingMask = .minYMargin
        nameLabel.frame = NSRect(x: 70, y: height - 34, width: width - 82, height: 20)
        nameLabel.font = .boldSystemFont(ofSize: 15)
        summaryLabel.frame = NSRect(x: 70, y: height - 54, width: width - 82, height: 16)
        summaryLabel.textColor = .secondaryLabelColor
        for label in [nameLabel, summaryLabel] {
            label.autoresizingMask = [.width, .minYMargin]
            label.lineBreakMode = .byTruncatingMiddle
        }
        footerLabel.frame = NSRect(x: 12, y: 5, width: width - 24, height: 16)
        footerLabel.autoresizingMask = [.width, .maxYMargin]
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.isHidden = true

        for (id, title, columnWidth) in [("name", "Name", 440.0), ("size", "Size", 90), ("modified", "Modified", 170)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = columnWidth
            column.headerCell.alignment = id == "size" ? .right : .left
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.usesAlternatingRowBackgroundColors = true
        outline.dataSource = self
        outline.delegate = self
        tree.frame = NSRect(x: 0, y: 0, width: width, height: height - 68)
        tree.autoresizingMask = [.width, .height]
        tree.hasVerticalScroller = true
        tree.autohidesScrollers = true
        tree.documentView = outline
        view.subviews = [icon, nameLabel, summaryLabel, tree, footerLabel]
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // A split archive's first volume (name.zip.001) counts as an archive, but the sandbox lets this extension read
        // only that file, not the other volumes: leave it to Quick Look's standard preview.
        if url.pathExtension == "001" {
            log.log("split archive \(url.lastPathComponent, privacy: .public): standard preview")
            return handler(CocoaError(.featureUnsupported))
        }
        let start = Date()
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        nameLabel.stringValue = url.lastPathComponent
        // Listing reads every header (a compressed tar is decompressed in full), so it runs off the main
        // thread, which Quick Look watches for hangs; the view is filled and the handler called on main.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Archive.list(url) }
            DispatchQueue.main.async {
                self.show(result)
                handler(nil)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                self.log.log("previewed \(url.lastPathComponent, privacy: .public) in \(ms) ms: \(self.summaryLabel.stringValue, privacy: .public)")
            }
        }
    }

    /// Fills the summary line and the tree from the listing, or shows why the archive couldn't be read.
    private func show(_ result: Result<ArchiveListing, Error>) {
        let listing: ArchiveListing
        do {
            listing = try result.get()
        } catch {
            summaryLabel.stringValue = "Can’t read this archive: \(error.localizedDescription)"
            tree.isHidden = true
            return
        }
        self.listing = listing
        let entries = listing.entries
        let folders = entries.filter(\.isDirectory).count
        let bytes = entries.reduce(Int64(0)) { $0 + $1.size }
        var parts = [listing.formatName, "\(Self.count(entries.count - folders, "file")), \(Self.count(folders, "folder"))"]
        if bytes > 0 { parts.append("\(Self.bytes(bytes)) uncompressed") }  // 0: sizes unknown, e.g. a single .gz
        parts.append("archive \(Self.bytes(listing.archiveSize))")
        if listing.hasEncryptedEntries { parts.append("🔒 encrypted") }
        summaryLabel.stringValue = parts.joined(separator: " · ")

        if entries.count > Self.cap {
            // Entries list folders before their contents, so the first `cap` form a complete tree.
            shown = Set(entries.prefix(Self.cap).map(\.path))
            footerLabel.stringValue = "… and \((entries.count - Self.cap).formatted()) more"
            footerLabel.isHidden = false
            tree.frame = NSRect(x: 0, y: 26, width: view.bounds.width, height: view.bounds.height - 94)
        }
        roots = nodes(in: "")
        outline.reloadData()
        // Small archives open fully expanded; bigger ones with a single top folder (the usual case) open that folder.
        if entries.count < 200 {
            outline.expandItem(nil, expandChildren: true)
        } else if roots.count == 1 {
            outline.expandItem(roots[0])
        }
    }

    // MARK: Outline

    /// The rows inside `folder`: its entries within the cap, sorted by name like Finder.
    private func nodes(in folder: String) -> [Node] {
        (listing?.children(of: folder) ?? [])
            .filter { shown?.contains($0.path) ?? true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(Node.init)
    }

    private func children(of item: Any?) -> [Node] {
        guard let node = item as? Node else { return roots }
        if node.children == nil { node.children = nodes(in: node.entry.path) }
        return node.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.entry.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = tableColumn?.identifier, let entry = (item as? Node)?.entry else { return nil }
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? Self.cell(id)
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = entry.name
            cell.imageView?.image = NSWorkspace.shared.icon(for: entry.isDirectory ? .folder
                : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        case "size":
            // 0 covers folders, links and sizes the format doesn't record (single-file .gz/.bz2/.xz).
            cell.textField?.stringValue = entry.size > 0 ? Self.bytes(entry.size) : "--"
        default:
            cell.textField?.stringValue = entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "--"
        }
        return cell
    }

    /// A reusable cell: a label, plus an icon in the Name column, kept vertically centred at any row height.
    private static func cell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        cell.identifier = id
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 2, y: 2, width: 96, height: 16)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(label)
        cell.textField = label
        if id.rawValue == "name" {
            let image = NSImageView(frame: NSRect(x: 2, y: 2, width: 16, height: 16))
            image.autoresizingMask = [.minYMargin, .maxYMargin]
            cell.addSubview(image)
            cell.imageView = image
            label.frame = NSRect(x: 22, y: 2, width: 76, height: 16)
        } else {
            label.textColor = .secondaryLabelColor
            label.alignment = id.rawValue == "size" ? .right : .left
        }
        return cell
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

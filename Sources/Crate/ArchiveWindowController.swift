import AppKit
import ArchiveCore
import Quartz
import UniformTypeIdentifiers

/// One window per archive: a path bar, the entry table and a status line, plus the toolbar and Archive menu actions.
/// Archive work runs off the main thread through `run` (progress, password prompts, errors).
final class ArchiveWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation,
    NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    let url: URL
    var onClose: () -> Void = {}

    private var listing: ArchiveListing?
    /// The password that last worked (or was entered) for this archive; remembered for this window only.
    private var password: String?
    /// The folder shown, as an entry path; "" is the top level.
    private var folder = ""
    /// With a search, the table lists matching entries from the whole archive instead of the folder.
    private var search = ""
    /// The table's entries in display order.
    private var rows: [ArchiveEntry] = []

    /// Files extracted for Quick Look and drags go here; removed when the window closes.
    private let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Crate-" + UUID().uuidString)
    private var previewFiles: [String: URL] = [:]
    private var previewItems: [URL] = []
    private var controlsPreview = false
    private let dragQueue = OperationQueue()

    private let table = EntryTableView()
    private let pathControl = NSPathControl()
    private let statusLabel = NSTextField(labelWithString: "Loading…")
    private var searchItem: NSSearchToolbarItem?

    private static var icons: [String: NSImage] = [:]
    private static var kinds: [String: String] = [:]
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 260)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.toolbarStyle = .unified
        window.setTitleWithRepresentedFilename(url.path)
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "Archive")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.contentView = makeContent()
        window.initialFirstResponder = table
        load(first: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: tempFolder)
    }

    // MARK: Loading and display

    private func load(first: Bool = false) {
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Archive.list(url) }
            DispatchQueue.main.async { self.loaded(result, first: first) }
        }
    }

    private func loaded(_ result: Result<ArchiveListing, Error>, first: Bool) {
        let name = url.lastPathComponent
        switch result {
        case .success(let listing):
            log.log("listed \(name, privacy: .public): \(listing.entries.count, privacy: .public) entries, \(listing.formatName, privacy: .public), editable: \(listing.isEditable, privacy: .public), encrypted: \(listing.hasEncryptedEntries, privacy: .public)")
            self.listing = listing
            previewFiles = [:]
            if !folder.isEmpty && !listing.entries.contains(where: { $0.isDirectory && $0.path == folder }) { folder = "" }
            reload()
            if first && listing.needsPassword && password == nil, let window {
                askPassword(for: name, wrong: false, on: window) { self.password = $0 }
            }
        case .failure(let error):
            log.error("can't list \(name, privacy: .public)")
            showError(error, on: window) { if self.listing == nil { self.close() } }
        }
    }

    /// Refills the table, keeping the selected entries (or selecting `paths`) where they are still listed.
    private func reload(selecting paths: Set<String>? = nil) {
        let keep = paths ?? Set(selection.map(\.path))
        let entries = listing.map { listing in
            search.isEmpty ? listing.children(of: folder) : listing.entries.filter { $0.name.localizedCaseInsensitiveContains(search) }
        } ?? []
        rows = sorted(entries)
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { keep.contains(rows[$0].path) }), byExtendingSelection: false)
        updatePathControl()
        updateStatus()
    }

    private func show(_ newFolder: String, selecting paths: Set<String> = []) {
        folder = newFolder
        search = ""
        searchItem?.searchField.stringValue = ""
        reload(selecting: paths)
        table.scrollRowToVisible(table.selectedRow >= 0 ? table.selectedRow : 0)
    }

    /// Folders first, then by the table's sort column (ties by name).
    private func sorted(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        let sort = table.sortDescriptors.first
        let key = sort?.key ?? "name"
        let ascending = sort?.ascending ?? true
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var order: ComparisonResult
            switch key {
            case "size": order = a.size == b.size ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
            case "modified": order = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case "kind": order = kind(of: a).localizedStandardCompare(kind(of: b))
            default: order = .orderedSame
            }
            if order == .orderedSame { order = a.name.localizedStandardCompare(b.name) }
            return order == (ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private func updatePathControl() {
        func item(_ title: String, _ icon: NSImage) -> NSPathControlItem {
            let item = NSPathControlItem()
            item.title = title
            item.image = icon.copy() as? NSImage
            item.image?.size = NSSize(width: 16, height: 16)
            return item
        }
        let parts = folder.isEmpty ? [] : folder.components(separatedBy: "/")
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        pathControl.pathItems = [item(url.lastPathComponent, NSWorkspace.shared.icon(forFile: url.path))] + parts.map { item($0, folderIcon) }
    }

    private func updateStatus() {
        guard let listing else {
            statusLabel.stringValue = "Loading…"
            return
        }
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        var parts = [itemCount(listing.entries.count), "\(bytes(listing.entries.reduce(0) { $0 + $1.size })) uncompressed",
                     "archive \(bytes(listing.archiveSize))", listing.formatName]
        if !listing.isEditable { parts.append("read-only") }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    private var selection: [ArchiveEntry] {
        table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    // MARK: Actions (toolbar, Archive menu, keys)

    @objc func goUp(_ sender: Any?) {
        guard !folder.isEmpty else { return }
        show(folder.components(separatedBy: "/").dropLast().joined(separator: "/"), selecting: [folder])
    }

    /// Return (or a double-click on a row): enter a folder, otherwise preview.
    @objc func openSelection(_ sender: Any?) {
        let entries = selection
        if entries.count == 1 && entries[0].isDirectory {
            show(entries[0].path)
        } else {
            showPreview()
        }
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        if sender.clickedRow >= 0 { openSelection(nil) }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let item = sender.clickedPathItem, let index = sender.pathItems.firstIndex(of: item) else { return }
        show(folder.components(separatedBy: "/").prefix(index).joined(separator: "/"))
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        search = sender.stringValue
        reload()
    }

    @objc func find(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    /// Extracts the selection (or everything) into a chosen folder, asking once about existing items.
    @objc func extract(_ sender: Any?) {
        guard let listing, let window else { return }
        let paths = selection.isEmpty ? nil : selection.map(\.path)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        panel.prompt = "Extract"
        panel.message = paths.map { "Extract \(itemCount($0.count)) from “\(url.lastPathComponent)” to:" } ?? "Extract everything in “\(url.lastPathComponent)” to:"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            let conflicts = Archive.conflicts(listing, paths: paths, in: destination)
            guard !conflicts.isEmpty else { return self.extract(listing, paths, to: destination, overwrite: .replace) }
            let alert = NSAlert()
            alert.messageText = conflicts.count == 1
                ? "“\((conflicts[0] as NSString).lastPathComponent)” already exists in “\(destination.lastPathComponent)”."
                : "\(itemCount(conflicts.count)) already exist in “\(destination.lastPathComponent)”."
            alert.informativeText = "Replace them with the ones from the archive, or skip them?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn: self.extract(listing, paths, to: destination, overwrite: .replace)
                case .alertSecondButtonReturn: self.extract(listing, paths, to: destination, overwrite: .skip)
                default: break
                }
            }
        }
    }

    private func extract(_ listing: ArchiveListing, _ paths: [String]?, to destination: URL, overwrite: OverwritePolicy) {
        run("Extracting from “\(url.lastPathComponent)”…", { password, progress in
            try Archive.extract(listing, paths: paths, to: destination, passphrase: password, overwrite: overwrite, progress: progress)
        }) {
            // Selected items land directly in the destination; reveal them, or the destination if they went deeper.
            let names = paths?.map { ($0 as NSString).lastPathComponent } ?? listing.children(of: "").map(\.name)
            let items = names.map { destination.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            NSWorkspace.shared.activateFileViewerSelecting(items.isEmpty ? [destination] : items)
        }
    }

    /// Extracts everything next to the archive without an extra wrapper folder when it has a single top item.
    @objc func extractHere(_ sender: Any?) {
        guard let listing else { return }
        let (destination, item) = Archive.smartExtractDestination(listing, in: url.deletingLastPathComponent())
        run("Extracting “\(url.lastPathComponent)”…", { password, progress in
            try Archive.extract(listing, to: destination, passphrase: password, progress: progress)
        }) {
            NSWorkspace.shared.activateFileViewerSelecting([item])
        }
    }

    @objc func addFiles(_ sender: Any?) {
        guard listing?.isEditable == true, let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { response in
            if response == .OK { self.add(panel.urls) }
        }
    }

    /// Confirms, then rewrites the archive with `urls` added to the folder shown.
    private func add(_ urls: [URL]) {
        guard let listing, listing.isEditable, let window, !urls.isEmpty else { return }
        let folder = self.folder
        let alert = NSAlert()
        alert.messageText = "Add \(itemCount(urls.count)) to “\(folder.isEmpty ? url.lastPathComponent : (folder as NSString).lastPathComponent)”?"
        alert.informativeText = "Items with the same name are replaced. Crate rewrites the whole archive to do this."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.run("Adding to “\(self.url.lastPathComponent)”…", { password, progress in
                try Archive.rewrite(listing, adding: urls, into: folder, passphrase: password, progress: progress)
            }) { self.load() }
        }
    }

    @objc func deleteEntries(_ sender: Any?) {
        guard let listing, listing.isEditable, let window else { return }
        let entries = selection
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(entries.count == 1 ? "“\(entries[0].name)”" : itemCount(entries.count)) from “\(url.lastPathComponent)”?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.run("Deleting from “\(self.url.lastPathComponent)”…", { password, progress in
                try Archive.rewrite(listing, removing: entries.map(\.path), passphrase: password, progress: progress)
            }) { self.load() }
        }
    }

    /// Runs archive work with this window's password (see `runWithPassword`) and remembers a password that worked.
    private func run(_ title: String?, _ work: @escaping (String?, @escaping (Double) -> Bool) throws -> Void,
                     then done: @escaping () -> Void) {
        guard let listing else { return }
        runWithPassword(title, on: window, name: url.lastPathComponent, needsPassword: listing.needsPassword,
                        password: password, work: work) { password in
            self.password = password
            done()
        }
    }

    // MARK: Validation

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .add || item.itemIdentifier == .delete {
            item.toolTip = listing?.isEditable == false ? "Read-only format" : item.label
        }
        return canPerform(item.action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(addFiles(_:)) || menuItem.action == #selector(deleteEntries(_:)) {
            menuItem.toolTip = listing?.isEditable == false ? "Read-only format" : nil
        }
        return canPerform(menuItem.action)
    }

    private func canPerform(_ action: Selector?) -> Bool {
        guard let listing else { return false }
        switch action {
        case #selector(goUp(_:)): return !folder.isEmpty
        case #selector(addFiles(_:)): return listing.isEditable
        case #selector(deleteEntries(_:)): return listing.isEditable && !selection.isEmpty
        case #selector(quickLook(_:)): return selection.contains { !$0.isDirectory }
        default: return true
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .flexibleSpace, .extract, .add, .delete, .quickLook, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .search {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search Archive"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            searchItem = item
            return item
        }
        let specs: [NSToolbarItem.Identifier: (label: String, symbol: String, action: Selector)] = [
            .back: ("Back", "chevron.left", #selector(goUp(_:))),
            .extract: ("Extract", "tray.and.arrow.down", #selector(extract(_:))),
            .add: ("Add", "plus", #selector(addFiles(_:))),
            .delete: ("Delete", "trash", #selector(deleteEntries(_:))),
            .quickLook: ("Quick Look", "eye", #selector(quickLook(_:))),
        ]
        guard let spec = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.label
        item.toolTip = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.action = spec.action
        item.isBordered = true
        item.isNavigational = id == .back
        return item
    }

    // MARK: Table

    private func makeContent() -> NSView {
        for (id, title, width) in [("name", "Name", 300.0), ("size", "Size", 80), ("modified", "Date Modified", 170), ("kind", "Kind", 150)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 50
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([.fileURL])

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        pathControl.pathStyle = .standard
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSView()
        for view in [pathControl, scrollView, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pathControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            pathControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
        ])
        return content
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
        let entry = rows[row]
        switch id.rawValue {
        case "name":
            cell.imageView?.image = icon(for: entry)
            // A search lists the whole archive, so show where each match is.
            let title = search.isEmpty ? entry.name : entry.path
            if entry.isEncrypted {
                let text = NSMutableAttributedString(string: title + " ", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
                let lock = NSTextAttachment()
                lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Encrypted")
                text.append(NSAttributedString(attachment: lock))
                cell.textField?.attributedStringValue = text
            } else {
                cell.textField?.stringValue = title
            }
        case "size":
            cell.textField?.stringValue = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        case "modified":
            cell.textField?.stringValue = entry.modified.map { Self.dateFormatter.string(from: $0) } ?? "—"
        default:
            cell.textField?.stringValue = kind(of: entry)
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = id.rawValue == "name" ? .byTruncatingMiddle : .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = image.trailingAnchor
        }
        if id.rawValue == "size" {
            text.alignment = .right
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func icon(for entry: ArchiveEntry) -> NSImage {
        let ext = entry.isDirectory ? "/" : (entry.name as NSString).pathExtension.lowercased()
        if let icon = Self.icons[ext] { return icon }
        let icon = NSWorkspace.shared.icon(for: entry.isDirectory ? .folder : UTType(filenameExtension: ext) ?? .data)
        Self.icons[ext] = icon
        return icon
    }

    private func kind(of entry: ArchiveEntry) -> String {
        if entry.isDirectory { return "Folder" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if let kind = Self.kinds[ext] { return kind }
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let kind = type.flatMap { $0.isDynamic ? nil : $0.localizedDescription } ?? "Document"
        Self.kinds[ext] = kind
        return kind
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        reload()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows[row].name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard controlsPreview, QLPreviewPanel.shared().isVisible else { return }
        preparePreview { QLPreviewPanel.shared().reloadData() }
    }

    // MARK: Drag out (file promises)

    private struct PromisedEntry {
        let listing: ArchiveListing
        let entry: ArchiveEntry
        let password: String?
        let tempFolder: URL
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let listing else { return nil }
        let entry = rows[row]
        let type = entry.isDirectory ? UTType.folder : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = PromisedEntry(listing: listing, entry: entry, password: password, tempFolder: tempFolder)
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? PromisedEntry)?.entry.name ?? "Untitled"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { dragQueue }

    /// Runs on `dragQueue`: extracts the entry into the temporary folder, then moves it to the URL Finder chose
    /// (Finder may have renamed it to avoid a clash).
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        guard let promise = filePromiseProvider.userInfo as? PromisedEntry else { return completionHandler(nil) }
        do {
            let folder = promise.tempFolder.appendingPathComponent(UUID().uuidString)
            try Archive.extract(promise.listing, paths: [promise.entry.path], to: folder, passphrase: promise.password)
            try FileManager.default.moveItem(at: folder.appendingPathComponent(promise.entry.name), to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
            DispatchQueue.main.async { self.dragFailed(error) }
        }
    }

    /// A drag-out failed: ask for the password (the user can drag again), or show the error.
    private func dragFailed(_ error: Error) {
        guard let window, window.attachedSheet == nil else { return }
        switch error as? ArchiveError {
        case .passphraseRequired?, .wrongPassphrase?:
            askPassword(for: url.lastPathComponent, wrong: password != nil, on: window) { entered in
                if let entered { self.password = entered }
            }
        default:
            showError(error, on: window)
        }
    }

    // MARK: Drop in (add)

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard listing?.isEditable == true, (info.draggingSource as AnyObject?) !== tableView,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.add(urls) }
        return true
    }

    // MARK: Quick Look

    /// Space, ⌘Y and the toolbar button toggle the preview panel.
    @objc func quickLook(_ sender: Any?) {
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            showPreview()
        }
    }

    private func showPreview() {
        guard selection.contains(where: { !$0.isDirectory }) else { return }
        preparePreview { QLPreviewPanel.shared().makeKeyAndOrderFront(nil) }
    }

    /// Extracts the selected files that aren't extracted yet into the temporary folder, then sets the preview items
    /// for the selection at that moment and calls `done`.
    private func preparePreview(then done: @escaping () -> Void) {
        guard let listing else { return }
        let jobs = selection.filter { !$0.isDirectory && previewFiles[$0.path] == nil }
            .map { ($0, tempFolder.appendingPathComponent(UUID().uuidString)) }
        run(nil, { password, _ in
            for (entry, destination) in jobs {
                try Archive.extract(listing, paths: [entry.path], to: destination, passphrase: password)
            }
        }) {
            for (entry, destination) in jobs { self.previewFiles[entry.path] = destination.appendingPathComponent(entry.name) }
            self.previewItems = self.selection.compactMap { $0.isDirectory ? nil : self.previewFiles[$0.path] }
            done()
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controlsPreview = true
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controlsPreview = false
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems[index] as NSURL
    }

    /// Arrow keys (and Space) in the panel go to the table, so the preview follows the selection.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        table.keyDown(with: event)
        return true
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        // The Quick Look panel's window notifications come here too (we are its delegate while previewing).
        guard notification.object as? NSWindow === window else { return }
        if controlsPreview { QLPreviewPanel.shared().orderOut(nil) }
        removeTemporaryFiles()
        onClose()
    }
}

private extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let extract = Self("extract")
    static let add = Self("add")
    static let delete = Self("delete")
    static let quickLook = Self("quickLook")
    static let search = Self("search")
}

/// The entry table. Space toggles Quick Look, Return opens, Delete deletes and ⌘[ goes back; the actions go to the
/// table's delegate, the ArchiveWindowController (also while the Quick Look panel forwards its keys here).
final class EntryTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var action: Selector?
        if modifiers.isEmpty {
            switch event.keyCode {
            case 49: action = #selector(ArchiveWindowController.quickLook(_:))           // Space
            case 36, 76: action = #selector(ArchiveWindowController.openSelection(_:))   // Return, Enter
            case 51, 117: action = #selector(ArchiveWindowController.deleteEntries(_:))  // Delete, Forward Delete
            default: break
            }
        } else if modifiers == .command && event.charactersIgnoringModifiers == "[" {
            action = #selector(ArchiveWindowController.goUp(_:))
        }
        if let action {
            NSApp.sendAction(action, to: delegate, from: self)
        } else {
            super.keyDown(with: event)
        }
    }
}

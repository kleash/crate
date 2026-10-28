import AppKit
import ArchiveCore
import SwiftUI
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "com.kleash.crate", category: "app")
/// "Extract Here with Crate" runs its extractions on this queue, one at a time (see `AppDelegate.extractItems`).
private let extractHereTurns = DispatchQueue(label: "com.kleash.crate.extract-here")

/// App lifecycle, the Welcome window, New Archive, the menu bar and the Finder services.
/// Archive windows are plain AppKit windows (ArchiveWindowController), one per archive.
@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var archiveWindows: [String: ArchiveWindowController] = [:]
    /// New Archive windows, kept until they close (`windowWillClose`).
    private var newArchiveWindows: [NSWindow] = []
    private var welcome: NSWindow?
    private var cascadePoint = NSPoint.zero
    private var handledService = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files to open and a service request that launched the app arrive before this; otherwise greet.
        let greet = archiveWindows.isEmpty && newArchiveWindows.isEmpty && welcome == nil && !handledService
        log.log("launched (welcome: \(greet, privacy: .public))")
        if greet { showWelcome() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    /// Reopen (Dock click) with no visible windows.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        log.log("reopen without windows: welcome")
        showWelcome()
        return true
    }

    /// Help menu: the repository page, or the page the item's `representedObject` path names.
    @objc func openGitHub(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://github.com/kleash/crate" + (sender.representedObject as? String ?? ""))!)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quitting while archive work runs: cancel it and let it clean up after itself (temporary and half-written
    /// files) before the process ends. Cancelled work stops at its next progress report, normally at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !runningOperations.isEmpty else { return .terminateNow }
        log.log("quit: cancelling \(runningOperations.count, privacy: .public) operation(s)")
        runningOperations.forEach { $0.cancel() }
        _ = operationsRunning.wait(timeout: .now() + 10)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        archiveWindows.values.forEach { $0.removeTemporaryFiles() }
    }

    // MARK: Opening

    /// Archives open in their own window; anything else goes into the New Archive sheet.
    private func open(_ urls: [URL]) {
        let archives = urls.filter(isArchive)
        let others = urls.filter { !isArchive($0) }
        log.log("open \(urls.count, privacy: .public) item(s): \(archives.count, privacy: .public) archive(s), \(others.count, privacy: .public) other(s)")
        archives.forEach(openArchive)
        if !others.isEmpty { showNewArchive(others) }
    }

    /// A file whose type is an archive (disk images other than ISO excluded: libarchive can't read them) or one of
    /// the types Crate opens (.docx, .apk, …), or the first volume of a split archive ("name.zip.001"), whatever
    /// type another app may have given .001 files.
    private func isArchive(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        guard values?.isDirectory == false, let type = values?.contentType else { return false }
        if url.pathExtension == "001" { return true }
        return type.conforms(to: .archive) && (!type.conforms(to: .diskImage) || type.identifier == "public.iso-image")
            || Self.archiveTypes.contains { type.conforms(to: $0) }
    }

    /// The types Info.plist declares as archives (public.archive would include disk images, which can't be read).
    private static let archiveTypes: [UTType] = ((Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])?
        .first { $0["CFBundleTypeName"] as? String == "Archive" }?["LSItemContentTypes"] as? [String] ?? []).compactMap { UTType($0) }

    private func openArchive(_ url: URL) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let controller = archiveWindows[key] {
            controller.showWindow(nil)
            return
        }
        let controller = ArchiveWindowController(url: url)
        archiveWindows[key] = controller
        controller.onClose = { [weak self] in
            self?.archiveWindows[key] = nil
            if self?.archiveWindows.isEmpty == true { self?.cascadePoint = .zero }
        }
        if let window = controller.window {
            if cascadePoint == .zero { window.center() }
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controller.showWindow(nil)
        welcome?.orderOut(nil)
        log.log("window opened: \(url.path, privacy: .public)")
    }

    @objc func showOpenPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.archiveTypes
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openArchive)
    }

    // MARK: Welcome and New Archive

    private func showWelcome() {
        if welcome == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Welcome to Crate"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: WelcomeView(
                openArchive: { [unowned self] in showOpenPanel(nil) },
                newArchive: { [unowned self] in showNewArchivePanel(nil) },
                drop: { [unowned self] urls in open(urls) }))
            window.center()
            welcome = window
        }
        welcome!.makeKeyAndOrderFront(nil)
    }

    @objc func showNewArchivePanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the files and folders to put in the new archive."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        showNewArchive(panel.urls)
    }

    /// The New Archive window for `items`, in front: the options, then on Create a progress sheet; once the archive
    /// is made it is revealed in Finder and the window closes. Opened by drops on the Dock icon and the Welcome
    /// window, File ▸ New Archive… and "Compress with Crate".
    private func showNewArchive(_ items: [URL]) {
        log.log("new archive window for \(items.count, privacy: .public) item(s): \(items.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "New Archive"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        let controller = NSHostingController(rootView: NewArchiveView(
            items: items,
            cancel: { [weak window] in window?.close() },
            create: { [weak self, weak window] options in
                if let self, let window { create(items, options, in: window) }
            }))
        window.contentViewController = controller
        window.setContentSize(controller.view.fittingSize)
        window.center()
        // Two at once (Compress with Crate twice in a row) would cover each other exactly: step down from the newest.
        if let last = newArchiveWindows.last {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        newArchiveWindows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        newArchiveWindows.removeAll { $0 === notification.object as? NSWindow }
    }

    private func create(_ items: [URL], _ options: NewArchiveOptions, in window: NSWindow) {
        let out = Archive.uniqueURL(in: options.folder, name: options.name, extension: options.format.fileExtension)
        var files: [URL] = []
        runWithPassword("Creating “\(out.lastPathComponent)”…", on: window, name: out.lastPathComponent, needsPassword: false, password: nil, work: { _, progress in
            files = try Archive.create(items, at: out, format: options.format, level: options.level, passphrase: options.password,
                                       excludeJunk: options.excludeJunk, volumeSize: options.volumeSize, progress: progress)
        }, done: { _ in
            log.log("created \(files.map(\.lastPathComponent).joined(separator: ", "), privacy: .public) in \(out.deletingLastPathComponent().path, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting(files)
            window.close()
        })
    }

    // MARK: Services (NSServices in Info.plist; NSApp.servicesProvider = self)

    /// "Compress with Crate": the New Archive window for the selected items (format, password, volumes, …).
    @objc func compressItems(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handledService = true
        let items = fileURLs(on: pboard)
        log.log("service compress: \(items.count, privacy: .public) item(s)")
        if !items.isEmpty { showNewArchive(items) }
    }

    /// "Extract Here with Crate": smart-extracts each archive next to itself, asking for a password if needed, with
    /// a progress window and Cancel. The extractions take turns, each choosing its destination when its turn comes:
    /// chosen all at once, two archives holding the same top-level item would both extract it to the same place.
    @objc func extractItems(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handledService = true
        let archives = fileURLs(on: pboard)
        log.log("service extract: \(archives.count, privacy: .public) archive(s)")
        for url in archives {
            DispatchQueue.global(qos: .userInitiated).async {
                let listing = Result { try Archive.list(url) }
                DispatchQueue.main.async {
                    switch listing {
                    case .failure(let error):
                        showError(error, on: nil)
                    case .success(let listing):
                        var target: (destination: URL, item: URL)?  // kept for a retry with another password
                        runWithPassword("Extracting “\(url.lastPathComponent)”…", on: nil, name: url.lastPathComponent,
                                        needsPassword: listing.needsPassword, password: nil, work: { password, progress in
                            try extractHereTurns.sync {
                                if target == nil { target = Archive.smartExtractDestination(listing, in: url.deletingLastPathComponent()) }
                                try Archive.extract(listing, to: target!.destination, passphrase: password, progress: progress)
                            }
                        }, done: { _ in
                            guard let item = target?.item else { return }
                            log.log("service extracted \(url.path, privacy: .public) to \(item.path, privacy: .public)")
                            NSWorkspace.shared.activateFileViewerSelecting([item])
                        })
                    }
                }
            }
        }
    }

    /// "Open with Crate": each archive in its own window, brought to the front.
    @objc func openItems(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handledService = true
        NSApp.activate(ignoringOtherApps: true)
        open(fileURLs(on: pboard))
    }

    private func fileURLs(on pboard: NSPasteboard) -> [URL] {
        pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Menu bar

    private func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu!.addItem($0) }
            return item
        }
        let services = menu("Services", [])
        NSApp.servicesMenu = services.submenu
        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu.submenu
        let reportIssue = item("Report an Issue…", #selector(openGitHub(_:)))
        reportIssue.representedObject = "/issues/new"  // appended to the repository URL
        let helpMenu = menu("Help", [item("Crate on GitHub", #selector(openGitHub(_:))), reportIssue])
        NSApp.helpMenu = helpMenu.submenu
        let upArrow = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let downArrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let main = NSMenu()
        [
            menu("Crate", [
                item("About Crate", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                .separator(),
                services,
                .separator(),
                item("Hide Crate", #selector(NSApplication.hide(_:)), "h"),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
                .separator(),
                item("Quit Crate", #selector(NSApplication.terminate(_:)), "q"),
            ]),
            menu("File", [
                item("New Archive…", #selector(showNewArchivePanel(_:)), "n"),
                item("Open…", #selector(showOpenPanel(_:)), "o"),
                .separator(),
                item("Close", #selector(NSWindow.performClose(_:)), "w"),
            ]),
            menu("Edit", [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "Z"),
                .separator(),
                item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
                .separator(),
                item("Find", #selector(ArchiveWindowController.find(_:)), "f"),
            ]),
            menu("Archive", [
                item("Extract…", #selector(ArchiveWindowController.extract(_:)), "e"),
                item("Extract Here", #selector(ArchiveWindowController.extractHere(_:)), "E"),
                .separator(),
                item("Add Files…", #selector(ArchiveWindowController.addFiles(_:))),
                item("Delete", #selector(ArchiveWindowController.deleteEntries(_:)), "\u{8}"),
                .separator(),
                item("Quick Look", #selector(ArchiveWindowController.quickLook(_:)), "y"),
                item("Open in Default App", #selector(ArchiveWindowController.openInApp(_:)), downArrow),
                item("Enclosing Folder", #selector(ArchiveWindowController.goUp(_:)), upArrow),
            ]),
            windowMenu,
            helpMenu,
        ].forEach(main.addItem)
        return main
    }
}

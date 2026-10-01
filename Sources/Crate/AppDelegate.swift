import AppKit
import ArchiveCore
import SwiftUI
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "com.sa.crate", category: "app")

/// App lifecycle, the Welcome window, New Archive, the menu bar and the Finder services.
/// Archive windows are plain AppKit windows (ArchiveWindowController), one per archive.
@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var archiveWindows: [String: ArchiveWindowController] = [:]
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
        let greet = archiveWindows.isEmpty && welcome == nil && !handledService
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

    /// A file whose type is an archive (disk images other than ISO excluded: libarchive can't read them).
    private func isArchive(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        guard values?.isDirectory == false, let type = values?.contentType else { return false }
        return type.conforms(to: .archive) && (!type.conforms(to: .diskImage) || type.identifier == "public.iso-image")
    }

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
        if let welcome, welcome.attachedSheet == nil { welcome.orderOut(nil) }
        log.log("window opened: \(url.path, privacy: .public)")
    }

    @objc func showOpenPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        // The types Info.plist declares as archives (public.archive would include disk images, which can't be read).
        let types = (Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])?
            .first { $0["CFBundleTypeName"] as? String == "Archive" }?["LSItemContentTypes"] as? [String] ?? []
        panel.allowedContentTypes = types.compactMap { UTType($0) }
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openArchive)
    }

    // MARK: Welcome and New Archive

    @discardableResult
    private func showWelcome() -> NSWindow {
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
        return welcome!
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

    /// The New Archive sheet, shown on the Welcome window.
    private func showNewArchive(_ items: [URL]) {
        log.log("new archive sheet requested for \(items.count, privacy: .public) item(s): \(items.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
        let window = showWelcome()
        let view = NewArchiveView(
            items: items,
            cancel: { if let sheet = window.attachedSheet { window.endSheet(sheet) } },
            create: { [unowned self] options in
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                create(items, options, on: window)
            })
        presentSheet(view, on: window)
    }

    private func create(_ items: [URL], _ options: NewArchiveOptions, on window: NSWindow) {
        let out = Archive.uniqueURL(in: options.folder, name: options.name, extension: options.format.fileExtension)
        runWithPassword("Creating “\(out.lastPathComponent)”…", on: window, name: out.lastPathComponent, needsPassword: false, password: nil, work: { _, progress in
            try Archive.create(items, at: out, format: options.format, level: options.level, passphrase: options.password,
                               excludeJunk: options.excludeJunk, progress: progress)
        }, done: { _ in
            log.log("created \(out.path, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([out])
        })
    }

    // MARK: Services (NSServices in Info.plist; NSApp.servicesProvider = self)

    /// "Compress with Crate": a ZIP next to the items, named after the single item or "Archive", no dialog.
    @objc func compressItems(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handledService = true
        let items = fileURLs(on: pboard)
        log.log("service compress: \(items.count, privacy: .public) item(s)")
        guard let first = items.first else { return }
        let out = Archive.uniqueURL(in: first.deletingLastPathComponent(), name: items.count == 1 ? first.lastPathComponent : "Archive",
                                    extension: WritableFormat.zip.fileExtension)
        runWithPassword(nil, on: nil, name: out.lastPathComponent, needsPassword: false, password: nil, work: { _, progress in
            try Archive.create(items, at: out, format: .zip, level: .normal, excludeJunk: true, progress: progress)
        }, done: { _ in
            log.log("service created \(out.path, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([out])
        })
    }

    /// "Extract Here with Crate": smart-extracts each archive next to itself, asking for a password if needed.
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
                        let (destination, item) = Archive.smartExtractDestination(listing, in: url.deletingLastPathComponent())
                        runWithPassword(nil, on: nil, name: url.lastPathComponent, needsPassword: listing.needsPassword, password: nil, work: { password, progress in
                            try Archive.extract(listing, to: destination, passphrase: password, progress: progress)
                        }, done: { _ in
                            log.log("service extracted \(url.path, privacy: .public) to \(item.path, privacy: .public)")
                            NSWorkspace.shared.activateFileViewerSelecting([item])
                        })
                    }
                }
            }
        }
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
        let helpMenu = menu("Help", [])
        NSApp.helpMenu = helpMenu.submenu
        let upArrow = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
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
                item("Enclosing Folder", #selector(ArchiveWindowController.goUp(_:)), upArrow),
            ]),
            windowMenu,
            helpMenu,
        ].forEach(main.addItem)
        return main
    }
}

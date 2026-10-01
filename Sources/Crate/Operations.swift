import AppKit
import ArchiveCore
import SwiftUI

extension ArchiveListing {
    /// Encrypted ZIP entries need a password. 7-Zip and RAR encryption can't be decrypted at all
    /// (ArchiveCore throws `unsupportedEncryption`), so asking would be pointless.
    var needsPassword: Bool { hasEncryptedEntries && writableFormat == .zip }
}

/// The archive work running now. Quitting cancels it and waits for it to stop, so that no temporary or
/// half-written file is left behind (AppDelegate.applicationShouldTerminate).
@MainActor var runningOperations: [ProgressModel] = []
let operationsRunning = DispatchGroup()

/// Runs `work` off the main thread with `password`, showing a progress sheet with Cancel on `window` when `title`
/// is set. Asks for a password first when `needsPassword` and none is known, and again (then runs `work` again) when
/// it throws `passphraseRequired` or `wrongPassphrase`. On success calls `done` with the password that worked.
/// Cancelling is silent; other errors are shown in an alert (a sheet on `window`, app-modal without one).
@MainActor
func runWithPassword(_ title: String?, on window: NSWindow?, name: String, needsPassword: Bool, password: String?,
                     work: @escaping (String?, @escaping (Double) -> Bool) throws -> Void,
                     done: @escaping (String?) -> Void) {
    if needsPassword && password == nil {
        return askPasswordThenRun(title, on: window, name: name, wrong: false, work: work, done: done)
    }
    let progress = ProgressModel()
    runningOperations.append(progress)
    let sheet: NSWindow?
    if let title, let window {
        sheet = presentSheet(ProgressSheet(title: title, model: progress), on: window)
    } else {
        sheet = nil
    }
    operationsRunning.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let failure: Error?
        do {
            try work(password, progress.update)
            failure = nil
        } catch {
            failure = error
        }
        operationsRunning.leave()
        DispatchQueue.main.async {
            runningOperations.removeAll { $0 === progress }
            if let sheet { window?.endSheet(sheet) }
            guard let failure else { return done(password) }
            switch failure as? ArchiveError {
            case .cancelled?: break
            case .passphraseRequired?: askPasswordThenRun(title, on: window, name: name, wrong: false, work: work, done: done)
            case .wrongPassphrase?: askPasswordThenRun(title, on: window, name: name, wrong: true, work: work, done: done)
            default: showError(failure, on: window)
            }
        }
    }
}

@MainActor
private func askPasswordThenRun(_ title: String?, on window: NSWindow?, name: String, wrong: Bool,
                                work: @escaping (String?, @escaping (Double) -> Bool) throws -> Void,
                                done: @escaping (String?) -> Void) {
    askPassword(for: name, wrong: wrong, on: window) { password in
        guard let password else { return }
        runWithPassword(title, on: window, name: name, needsPassword: false, password: password, work: work, done: done)
    }
}

/// Asks for the password of archive `name`: a sheet on `window`, or an app-modal alert without one.
/// `completion` gets nil when the user cancels.
@MainActor
func askPassword(for name: String, wrong: Bool, on window: NSWindow?, completion: @escaping (String?) -> Void) {
    let alert = NSAlert()
    alert.messageText = wrong ? "Wrong password" : "“\(name)” is encrypted"
    alert.informativeText = wrong ? "The password for “\(name)” is incorrect. Try again." : "Enter its password to open the files inside."
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    let finish = { (response: NSApplication.ModalResponse) in
        completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
    }
    if let window {
        alert.beginSheetModal(for: window, completionHandler: finish)
    } else {
        NSApp.activate(ignoringOtherApps: true)
        finish(alert.runModal())
    }
}

/// Shows `error` in an alert: a sheet on `window`, or app-modal without one. Then calls `done`.
@MainActor
func showError(_ error: Error, on window: NSWindow?, then done: @escaping () -> Void = {}) {
    log.error("error: \(error.localizedDescription, privacy: .public)")
    let alert = NSAlert(error: error)
    if case .unsupportedEncryption? = error as? ArchiveError {
        alert.informativeText = "The archive library built into macOS can’t decrypt encrypted 7-Zip or RAR archives."
    }
    if let window {
        alert.beginSheetModal(for: window) { _ in done() }
    } else {
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        done()
    }
}

/// Shows a SwiftUI view as a sheet on `window`; returns the sheet window (end it with `window.endSheet`).
@MainActor @discardableResult
func presentSheet<V: View>(_ view: V, on window: NSWindow) -> NSWindow {
    let controller = NSHostingController(rootView: view)
    let sheet = NSWindow(contentViewController: controller)
    sheet.styleMask.remove(.resizable)
    sheet.setContentSize(controller.view.fittingSize)  // the window starts at 1×32 until SwiftUI's first layout
    window.beginSheet(sheet)
    return sheet
}

/// "1 item", "12 items", "1,234 items".
func itemCount(_ count: Int) -> String {
    count == 1 ? "1 item" : "\(count.formatted()) items"
}

/// The progress shown by a ProgressSheet. `update` is the progress closure ArchiveCore calls on the worker thread;
/// `fraction` is only set on the main queue and the cancel flag is behind a lock, hence @unchecked Sendable.
final class ProgressModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var fraction = 0.0
    private let lock = NSLock()
    private var cancelled = false

    /// Called on the worker thread; returns false once Cancel was pressed, which makes ArchiveCore stop.
    func update(_ fraction: Double) -> Bool {
        DispatchQueue.main.async { self.fraction = fraction }
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

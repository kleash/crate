import Cocoa
import Quartz

// Entry point is NSExtensionMain (linker flag in Package.swift); this class is the
// NSExtensionPrincipalClass named in Resources/CrateQuickLook-Info.plist.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        handler(nil)
    }
}

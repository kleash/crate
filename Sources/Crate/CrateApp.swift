import SwiftUI

@main
struct CrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Crate") {
            Text("Crate")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {}

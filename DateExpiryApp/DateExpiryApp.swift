import SwiftUI

@main
struct DateExpiryApp: App {
    @UIApplicationDelegateAdaptor(DateExpiryAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

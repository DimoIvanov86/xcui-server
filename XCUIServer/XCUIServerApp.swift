import SwiftUI

// Empty host app; the UI-test runner needs a target application to build against.
@main
struct XCUIServerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

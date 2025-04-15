import SwiftUI

@main
struct LinkplayReceiverApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 360) // Set initial minimum size
        }
        .windowStyle(DefaultWindowStyle()) // Or try .hiddenTitleBarWindowStyle()
    }
}


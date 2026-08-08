import AppKit
import Foundation
import SwiftUI

#if !TESTING
@main
struct SystemBarApp: App {
    @StateObject private var monitor = UnifiedMonitor()

    var body: some Scene {
        MenuBarExtra {
            RootView(monitor: monitor)
                .onAppear {
                    monitor.start()
                }
        } label: {
            Image(systemName: "percent")
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
#endif

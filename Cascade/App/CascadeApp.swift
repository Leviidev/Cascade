import SwiftUI

@main
struct CascadeApp: App {
    @StateObject private var emulatorState = EmulatorState()
    @StateObject private var libraryManager = GameLibraryManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(emulatorState)
                .environmentObject(libraryManager)
                .preferredColorScheme(.dark)
        }
    }
}

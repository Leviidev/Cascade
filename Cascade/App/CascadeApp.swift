import SwiftUI

@main
struct CascadeApp: App {
    @StateObject private var emulatorState  = EmulatorState()
    @StateObject private var libraryManager = GameLibraryManager()
    @StateObject private var cheatManager   = CheatManager()
    @StateObject private var keepAlive      = BackgroundKeepAlive()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(emulatorState)
                .environmentObject(libraryManager)
                .environmentObject(cheatManager)
                .environmentObject(keepAlive)
                .preferredColorScheme(.dark)
        }
    }
}

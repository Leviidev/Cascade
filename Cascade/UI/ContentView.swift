import SwiftUI

struct ContentView: View {
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var library: GameLibraryManager
    @State private var selectedTab: Tab = .library

    enum Tab { case library, settings }

    var body: some View {
        Group {
            if emulatorState.status == .running || emulatorState.status == .paused {
                EmulatorView()
                    .transition(.opacity)
            } else {
                mainTabView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: emulatorState.status)
        .alert("Error", isPresented: $emulatorState.showError) {
            Button("OK") { emulatorState.showError = false }
        } message: {
            Text(emulatorState.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "gamecontroller.fill")
                }
                .tag(Tab.library)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(Tab.settings)
        }
        .tint(Color.cascadeBlue)
    }
}

import AppKit
import SwiftUI

@main
struct ColimaXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var store: AppStore

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        let store = AppStore(settings: settings, services: .forLaunch())
        if AppServices.isUITestLaunch {
            // Fixture samples must never land in the real app's history (same Application Support folder).
            store.resources.historyDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("colimax-uitest-metrics", isDirectory: true)
        }
        if AppServices.isUITestLaunch,
           let raw = ProcessInfo.processInfo.environment["COLIMAX_UI_TEST_SCREEN"], let screen = Screen(rawValue: raw) {
            store.screen = screen
        }
        #if COLIMAX_UI_TESTING
        // Demo screenshots: open the Containers screen with this demo container selected.
        if AppServices.isUITestLaunch, let key = ProcessInfo.processInfo.environment["COLIMAX_UI_TEST_FOCUS"] {
            store.focusContainerID = DemoFixtures.containerID(key)
        }
        #endif
        _store = State(initialValue: store)
        AppDelegate.store = store
    }

    var body: some Scene {
        Window("ColimaX", id: "main") {
            MainWindow()
                .environment(store)
                .environment(settings)
                .transaction { if AppServices.isUITestLaunch { $0.disablesAnimations = true; $0.animation = nil } }
                .task { store.bootstrap() }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh") { Task { await store.refreshProfiles(); await store.reloadAll() } }
                    .keyboardShortcut("r")
                Button("Setup Assistant…") { store.setupModel.isPresented = true }
            }
            CommandMenu("Go") {
                ForEach(Array(Screen.shortcutOrder.enumerated()), id: \.element) { index, screen in
                    Button(screen.title) { store.screen = screen }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                ForEach(Screen.allCases.filter { !Screen.shortcutOrder.contains($0) && $0 != .preferences }) { screen in
                    Button(screen.title) { store.screen = screen }
                }
            }
        }

        MenuBarExtra {
            MenuContentView()
                .environment(store)
                .environment(settings)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environment(store)
                .environment(settings)
                .frame(width: 560, height: 640)
        }
    }
}

private struct MenuBarLabel: View {
    let store: AppStore

    var body: some View {
        // `.task` on the label runs at app launch, even when the main window is closed.
        Image(nsImage: MenuBarIcon.image(for: store.operations.isOperationRunning ? .busy : (store.isRunning ? .running : .stopped)))
            .task { store.bootstrap() }
    }
}

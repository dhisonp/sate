import SwiftUI

/// Navigation is a typed path so the scene can tell which conversation is on
/// screen — that is what `scenePhase` changes have to be forwarded to.
enum SateRoute: Hashable {
    case chat(UUID)
    case settings
}

@main
struct SateApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }
}

private struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [SateRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ConversationListView(path: $path)
                .navigationDestination(for: SateRoute.self) { route in
                    switch route {
                    case .chat(let id):
                        // The view model is owned by the environment, not by this
                        // view: navigating back must not cancel a live generation.
                        ChatView(vm: env.viewModel(for: id))
                    case .settings:
                        SettingsView()
                    }
                }
        }
        .task {
            await env.bootstrap()
            await runDemoIfRequested()
        }
        .onChange(of: scenePhase) { _, phase in
            // Only the conversation actually on screen needs to know: it owns the
            // background-task guard that decides whether to keep streaming for the
            // ~25 s the system allows, or commit the partial as interrupted.
            guard let id = activeConversationID else { return }
            env.viewModel(for: id).handleScenePhase(phase == .active)
        }
    }

    /// Launch hook for automated end-to-end runs: opens a conversation and sends
    /// a prompt without any synthetic tapping, so `scripts/e2e.sh` can screenshot
    /// a real streaming response deterministically. Inert unless SATE_DEMO=1.
    private func runDemoIfRequested() async {
        let environmentValues = ProcessInfo.processInfo.environment
        guard environmentValues["SATE_DEMO"] == "1", let id = await env.newConversation() else { return }
        path = [.chat(id)]
        let vm = env.viewModel(for: id)
        await vm.load()
        vm.input = environmentValues["SATE_DEMO_PROMPT"]
            ?? "Explain what a Server-Sent Event is, and why it suits token streaming."
        await vm.send()
    }

    private var activeConversationID: UUID? {
        for route in path.reversed() {
            if case .chat(let id) = route { return id }
        }
        return nil
    }
}

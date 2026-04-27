import SwiftUI

/// Top-level scene: holds the host store and TOFU coordinator,
/// presents the host list inside a NavigationStack, and hosts the
/// single TOFU sheet that all child views drive.
struct ContentView: View {
    @State private var store = HostStore()
    @State private var tofu = TOFUCoordinator()

    var body: some View {
        NavigationStack {
            HostListView(
                store: store,
                tofu: tofu,
                keyData: SmokeTestConfig.privateKeyData
            )
        }
        .sheet(
            isPresented: Binding(
                get: { tofu.pendingPrompt != nil },
                set: { _ in /* dismiss only via button → resolve */ }
            )
        ) {
            if let prompt = tofu.pendingPrompt {
                TOFUPromptSheet(prompt: prompt) { tofu.resolve($0) }
            }
        }
    }
}

#Preview {
    ContentView()
}

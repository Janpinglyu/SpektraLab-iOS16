//  SpektraLabApp.swift — the app's entry point.
//
//  One scene, one view model, one engine. The engine is created here and
//  lives for the app's life: it holds the baked constants (9.4 MB), the
//  setup cache and the GPU, and creating a second one would cost all three
//  again.

import SwiftUI

@main
struct SpektraLabApp: App {
    @StateObject private var model = ViewModel()

    init() {
#if DEBUG
        DecoderProbe.runIfRequested()
#endif
        // Before anything else can fail: import crashes here never reach a
        // `catch`, so this is the only way the app can report its own death.
        CrashLog.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

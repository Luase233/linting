import SwiftUI

@main
struct BGMPrototypeApp: App {
    @StateObject private var model: BGMViewModel

    init() {
        LegacyHealthCleanup.run()
        _model = StateObject(wrappedValue: BGMViewModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    #if DEBUG
                    await DeviceSmokeChecks.run(model)
                    #endif
                }
        }
    }
}

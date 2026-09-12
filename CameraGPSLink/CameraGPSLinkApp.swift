import SwiftUI

@main
struct CameraGPSLinkApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel: CameraGPSLinkAppModel

    init() {
        _appModel = StateObject(wrappedValue: CameraGPSLinkAppModel.makeForCurrentProcess())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                #if DEBUG
                    .modifier(UITestURLHandling())
                    .modifier(UITestAppearance())
                #endif
                .onAppear {
                    appModel.handleScenePhase(.active)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        appModel.handleScenePhase(.active)
                    case .inactive:
                        appModel.handleScenePhase(.inactive)
                    case .background:
                        appModel.handleScenePhase(.background)
                        appModel.scheduleBackgroundRefresh()
                    @unknown default:
                        appModel.handleScenePhase(.inactive)
                    }
                }
        }
    }
}

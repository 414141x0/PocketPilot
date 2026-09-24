import AppIntents
import RunActivity
import SwiftUI

@main
struct PocketPilotApp: App {
    @State private var setup: Setup
    @State private var model: RunModel

    init() {
        let setup = Setup()
        let model = RunModel()
        self.setup = setup
        self.model = model
        AppDependencyManager.shared.add(dependency: setup)
        AppDependencyManager.shared.add(dependency: model)
        // The existential cast keys the registry by RunControl, which is what StopRunIntent resolves.
        AppDependencyManager.shared.add(dependency: model as any RunControl)
    }

    var body: some Scene {
        WindowGroup {
            RunView(setup: setup, model: model)
        }
    }
}

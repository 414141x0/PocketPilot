import AppIntents
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
    }

    var body: some Scene {
        WindowGroup {
            RunView(setup: setup, model: model)
        }
    }
}


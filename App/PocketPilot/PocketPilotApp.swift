import SwiftUI

@main
struct PocketPilotApp: App {
    @State private var setup = Setup()

    var body: some Scene {
        WindowGroup {
            RunView(setup: setup)
        }
    }
}

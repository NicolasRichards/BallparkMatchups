import SwiftUI

@main
struct BallparkMatchupsApp: App {
    init() {
        TipJar.shared.startListening()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

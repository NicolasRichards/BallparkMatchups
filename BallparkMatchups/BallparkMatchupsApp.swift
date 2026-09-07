import SwiftUI

@main
struct BallparkMatchupsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await TipJar.shared.listenForTransactions() }
        }
    }
}

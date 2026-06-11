import SwiftUI

@main
struct PainEnjoyerApp: App {
    init() {
        // Must re-register every launch: when any app writes a running workout
        // to Health, iOS briefly wakes us and the observer triggers a sync.
        HealthKitService.shared.registerBackgroundSync()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

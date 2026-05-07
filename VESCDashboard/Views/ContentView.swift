import SwiftUI

struct ContentView: View {
    @StateObject private var vm = TelemetryViewModel()
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        if onboardingComplete {
            DashboardView(vm: vm)
        } else {
            OnboardingView()
                .transition(.opacity)
        }
    }
}

#Preview {
    ContentView()
}

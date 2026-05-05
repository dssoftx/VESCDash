import SwiftUI

struct ContentView: View {
    @StateObject private var vm = TelemetryViewModel()

    var body: some View {
        DashboardView(vm: vm)
    }
}

#Preview {
    ContentView()
}

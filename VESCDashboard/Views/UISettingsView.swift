import SwiftUI

struct UISettingsView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    private var ui: UISettings { vm.uiSettings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { vm.uiSettings.suppressIdleAnomalies },
                        set: { vm.uiSettings.suppressIdleAnomalies = $0; vm.saveUISettings() }
                    )) {
                        Label("Suppress Idle Anomalies", systemImage: "waveform.slash")
                    }
                } footer: {
                    Text("Clamps speed and duty cycle to 0 when the board is stationary (speed < 1 km/h, duty < 1%).")
                        .font(.caption)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { vm.uiSettings.reduceStatisticsAnimations },
                        set: { vm.uiSettings.reduceStatisticsAnimations = $0; vm.saveUISettings() }
                    )) {
                        Label("Reduce Animations", systemImage: "number")
                    }
                } footer: {
                    Text("Disables numeric fly-in/out transitions for cleaner readability at a glance.")
                        .font(.caption)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { vm.uiSettings.lightMode },
                        set: { vm.uiSettings.lightMode = $0; vm.saveUISettings() }
                    )) {
                        Label("Light Mode", systemImage: "sun.max")
                    }
                } footer: {
                    Text("Switches the dashboard to a light colour scheme.")
                        .font(.caption)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { vm.uiSettings.showGPSSpeed },
                        set: { vm.uiSettings.showGPSSpeed = $0; vm.saveUISettings() }
                    )) {
                        Label("GPS Speed Overlay", systemImage: "location.fill")
                    }
                } footer: {
                    Text("Shows phone GPS speed under the VESC speed gauge. Useful for verifying accuracy on high-speed runs. Requires location permission.")
                        .font(.caption)
                }
            }
            .navigationTitle("UI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(ui.lightMode ? .light : .dark)
    }
}

#Preview {
    UISettingsView(vm: TelemetryViewModel())
}

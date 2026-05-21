import SwiftUI

struct UISettingsView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var emptyVoltageText = ""
    @State private var fullVoltageText  = ""

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

                Section {
                    Toggle(isOn: Binding(
                        get: { vm.uiSettings.runVerificationMode },
                        set: { vm.uiSettings.runVerificationMode = $0; vm.saveUISettings() }
                    )) {
                        Label("Run Verification", systemImage: "location.circle.fill")
                    }
                } footer: {
                    Text("Swaps the main speed display to GPS speed so you can verify VESC accuracy at speed. A green arrow appears over the number. Requires GPS Speed Overlay to be enabled.")
                        .font(.caption)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { vm.uiSettings.showBatteryPercentage },
                        set: { vm.uiSettings.showBatteryPercentage = $0; vm.saveUISettings() }
                    )) {
                        Label("Show Battery %", systemImage: "battery.100")
                    }

                    if vm.uiSettings.showBatteryPercentage {
                        HStack {
                            Text("Empty Voltage").foregroundStyle(.secondary)
                            Spacer()
                            TextField("e.g. 33.0", text: $emptyVoltageText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: emptyVoltageText) { _, v in
                                    if let d = Double(v), d > 0 {
                                        vm.uiSettings.batteryEmptyVoltage = d
                                        vm.saveUISettings()
                                    }
                                }
                            Text("V").foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Full Voltage").foregroundStyle(.secondary)
                            Spacer()
                            TextField("e.g. 42.0", text: $fullVoltageText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: fullVoltageText) { _, v in
                                    if let d = Double(v), d > 0 {
                                        vm.uiSettings.batteryFullVoltage = d
                                        vm.saveUISettings()
                                    }
                                }
                            Text("V").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Replaces the Voltage box with battery percentage. Set the pack voltage at empty and full charge to calibrate the reading.")
                        .font(.caption)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { vm.uiSettings.showMotorDetection },
                        set: { vm.uiSettings.showMotorDetection = $0; vm.saveUISettings() }
                    )) {
                        Label("Experimental Motor Detection", systemImage: "wand.and.stars")
                    }
                } footer: {
                    Text("Enables the Motor Wizard in the menu. Detection is experimental and may write incorrect values — only use on a secured, stationary motor with no load attached.")
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
        .onAppear {
            emptyVoltageText = String(format: "%.1f", vm.uiSettings.batteryEmptyVoltage)
            fullVoltageText  = String(format: "%.1f", vm.uiSettings.batteryFullVoltage)
        }
    }
}

#Preview {
    UISettingsView(vm: TelemetryViewModel())
}

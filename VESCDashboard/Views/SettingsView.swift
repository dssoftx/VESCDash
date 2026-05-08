import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var polePairs: String = ""
    @State private var gearRatio: String = ""
    @State private var wheelDiameter: String = ""
    @State private var newCANID: String = ""

    var body: some View {
        NavigationStack {
            Form {
                drivetrainSection
                speedPreviewSection
                canNetworkSection
                connectionSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { applyAndDismiss() }
                }
            }
            .onAppear { loadCurrentValues() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var drivetrainSection: some View {
        Section {
            LabeledContent("Motor Pole Pairs") {
                TextField("15", text: $polePairs)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Gear Ratio") {
                TextField("0", text: $gearRatio)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Wheel Diameter (mm)") {
                TextField("241", text: $wheelDiameter)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Drivetrain")
        } footer: {
            Text("""
            Speed = (ERPM ÷ polePairs ÷ gearRatio) × wheelCircumference
            Gear ratio 0 = direct drive / hub motor (1:1 internally).
            Pole pairs = motor poles ÷ 2 (e.g. 30-pole motor = 15 pairs).
            """)
            .font(.caption)
        }
    }

    private var speedPreviewSection: some View {
        Section {
            HStack {
                Text("Speed at 10,000 ERPM")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f km/h", vm.settings.speedKMH(erpm: 10_000)))
            }
        }
    }

    private var canNetworkSection: some View {
        Section {
            // Local (master) VESC row
            Button { vm.selectVESC(canID: nil) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local (BLE)")
                            .foregroundStyle(.primary)
                        if let ver = vm.localFWVersion {
                            Text("fw \(ver)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Master — directly connected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if vm.selectedCANID == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.cyan)
                            .fontWeight(.semibold)
                    }
                }
            }

            // CAN nodes (manually added + scan-discovered)
            ForEach(vm.canNodes) { node in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        Button { vm.selectVESC(canID: node.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.name)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 4) {
                                        Text("CAN ID \(node.id)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if let ver = node.hwVersion {
                                            Text("· fw \(ver)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if vm.persistedCANIDs.contains(node.id) {
                                            Text("· saved")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                Spacer()
                                if vm.selectedCANID == node.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.cyan)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                        Button {
                            vm.removeCANNode(id: node.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                                .padding(.leading, 12)
                        }
                        .buttonStyle(.plain)
                    }

                    if vm.isConnected {
                        HStack(spacing: 8) {
                            Button { vm.fetchMotorConfigFrom(canID: node.id) } label: {
                                Label("Read Config", systemImage: "arrow.down.circle")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button { vm.sendMotorLimitsTo(canID: node.id) } label: {
                                Label("Apply Settings", systemImage: "arrow.up.circle")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            // Manual add row
            HStack {
                TextField("Add CAN ID (0–254)", text: $newCANID)
                    .keyboardType(.numberPad)
                Button("Add") {
                    if let id = Int(newCANID), (0...254).contains(id) {
                        vm.addCANNode(id: id)
                        newCANID = ""
                    }
                }
                .disabled({
                    guard let id = Int(newCANID) else { return true }
                    return !(0...254).contains(id)
                }())
            }

            // Scan button
            Button { vm.pingCAN() } label: {
                HStack {
                    if vm.isScanningCAN {
                        ProgressView().scaleEffect(0.8)
                        Text("Scanning…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text("Scan CAN Bus")
                    }
                }
            }
            .disabled(!vm.isConnected || vm.isScanningCAN)
        } header: {
            Text("Connected VESCs")
        } footer: {
            Text("Type a CAN ID and tap Add to save it permanently. Scan finds nodes automatically (may cause a brief motor beep).")
                .font(.caption)
        }
    }

    private var connectionSection: some View {
        Group {
            if vm.isConnected {
                Section {
                    Button("Disconnect", role: .destructive) {
                        vm.bleManager.disconnect()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadCurrentValues() {
        polePairs     = fmt(vm.settings.motorPolePairs)
        gearRatio     = fmt(vm.settings.gearRatio)
        wheelDiameter = fmt(vm.settings.wheelDiameterMM)
    }

    private func applyAndDismiss() {
        if let v = Double(polePairs),     v > 0  { vm.settings.motorPolePairs  = v }
        if let v = Double(gearRatio),     v >= 0 { vm.settings.gearRatio       = v }
        if let v = Double(wheelDiameter), v > 0  { vm.settings.wheelDiameterMM = v }
        vm.saveSettings()
        dismiss()
    }

    private func fmt(_ d: Double) -> String {
        guard d.isFinite, d >= Double(Int.min), d <= Double(Int.max) else { return String(format: "%.3g", d) }
        return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
    }
}

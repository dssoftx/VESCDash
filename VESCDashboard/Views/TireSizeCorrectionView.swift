import SwiftUI

struct TireSizeCorrectionView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var applyResult: (success: Bool, message: String)? = nil
    @State private var showConfirm = false

    private var ui: UISettings { vm.uiSettings }

    // MARK: - Derived values

    private var vescSpeed: Double { abs(vm.speedKMH) }
    private var gpsSpeed: Double? { vm.gpsSpeedKMH }
    private var isMoving: Bool { vescSpeed > 3.0 && (gpsSpeed ?? 0) > 3.0 }

    private var currentDiameterMM: Float {
        vm.drivetrainFromMCCONF()?.wheelDiameterMM ?? Float(vm.settings.wheelDiameterMM)
    }

    private var drivetrain: (poles: Int, gearRatio: Float, wheelDiameterMM: Float)? {
        if let dt = vm.drivetrainFromMCCONF() { return dt }
        let s = vm.settings
        guard s.motorPolePairs > 0, s.wheelDiameterMM > 0 else { return nil }
        return (Int(s.motorPolePairs * 2), Float(s.gearRatio == 0 ? 1 : s.gearRatio), Float(s.wheelDiameterMM))
    }

    private var correctionRatio: Double? {
        guard let gps = gpsSpeed, isMoving else { return nil }
        return gps / vescSpeed
    }

    private var suggestedDiameterMM: Float? {
        guard let ratio = correctionRatio else { return nil }
        return Float(Double(currentDiameterMM) * ratio)
    }

    private var speedError: Double? {
        guard let gps = gpsSpeed else { return nil }
        return gps - vescSpeed
    }

    private var isAccurate: Bool {
        guard let err = speedError else { return false }
        return abs(err) < 0.5
    }

    private func maxSpeedKMH(diameterMM: Float) -> Double? {
        guard let dt = drivetrain else { return nil }
        let polePairs = Float(dt.poles) / 2.0
        let ratio = dt.gearRatio == 0 ? 1.0 : dt.gearRatio
        let circumM = Float.pi * diameterMM / 1000.0
        let maxERPM = vm.motorProfile.maxERPM
        guard maxERPM > 0 else { return nil }
        return Double(maxERPM / polePairs / ratio / 60.0 * circumM * 3.6)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                if !ui.showGPSSpeed {
                    gpsRequiredSection
                }
                currentSetupSection
                liveAccuracySection
                if let suggested = suggestedDiameterMM {
                    correctionSection(suggested: suggested)
                } else {
                    waitingSection
                }
                if let result = applyResult {
                    resultSection(result)
                }
            }
            .navigationTitle("Tire Size Correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(ui.lightMode ? .light : .dark)
    }

    // MARK: - GPS required

    private var gpsRequiredSection: some View {
        Section {
            Label("Enable GPS Speed Overlay in UI Settings to use this feature.", systemImage: "location.slash")
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Current setup

    private var currentSetupSection: some View {
        Section {
            row("Wheel Diameter", value: String(format: "%.1f mm", currentDiameterMM),
                note: vm.hasMCConfCache ? "from MCCONF" : "from local settings")
            if let dt = drivetrain {
                row("Pole Pairs", value: "\(dt.poles / 2)")
                row("Gear Ratio", value: String(format: "%.3f", dt.gearRatio))
            }
            if vm.motorProfile.maxERPM > 0 {
                row("Profile Max ERPM", value: String(format: "%.0f", vm.motorProfile.maxERPM))
            }
        } header: {
            Text("Current Configuration")
        }
    }

    // MARK: - Live accuracy

    private var liveAccuracySection: some View {
        Section {
            HStack {
                Text("VESC Speed")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f km/h", vescSpeed))
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }

            HStack {
                Text("GPS Speed")
                    .foregroundStyle(.secondary)
                Spacer()
                if let gps = gpsSpeed {
                    Text(String(format: "%.1f km/h", gps))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                } else {
                    Text(ui.showGPSSpeed ? "Waiting for GPS…" : "GPS not enabled")
                        .foregroundStyle(.secondary)
                }
            }

            if let err = speedError {
                HStack {
                    Text("Error")
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text(String(format: "%+.2f km/h", err))
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(abs(err) < 0.5 ? .green : abs(err) < 2.0 ? .orange : .red)
                        Image(systemName: isAccurate ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(isAccurate ? .green : abs(err) < 2.0 ? .orange : .red)
                    }
                }
            }
        } header: {
            Text("Live Accuracy")
        } footer: {
            if isAccurate {
                Text("Within 0.5 km/h — no correction needed.")
            } else if !isMoving {
                Text("Ride at speed (> 3 km/h) with GPS active for an accurate reading.")
            } else {
                Text("Higher speed gives a more accurate diameter ratio. Aim for ≥ 15 km/h.")
            }
        }
    }

    // MARK: - Waiting state

    private var waitingSection: some View {
        Section {
            Label("Ride at speed with GPS active to generate a suggestion.", systemImage: "figure.outdoor.cycle")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        } header: {
            Text("Suggested Correction")
        }
    }

    // MARK: - Correction suggestion

    private func correctionSection(suggested: Float) -> some View {
        let deltaMM = suggested - currentDiameterMM
        let deltaPct = Double(deltaMM) / Double(currentDiameterMM) * 100.0
        return AnyView(Section {
            row("Current Diameter", value: String(format: "%.1f mm", currentDiameterMM))
            HStack {
                Text("Suggested Diameter")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f mm", suggested))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.dynetraOrange)
                    Text(String(format: "%+.1f mm (%+.1f%%)", deltaMM, deltaPct))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let before = maxSpeedKMH(diameterMM: currentDiameterMM),
               let after  = maxSpeedKMH(diameterMM: suggested) {
                HStack {
                    Text("Profile Max Speed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f", before))
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f km/h", after))
                            .font(.system(.body, design: .rounded).weight(.medium))
                    }
                }
            }

            Button {
                showConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Label(String(format: "Apply %.1f mm to VESC", suggested), systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    Spacer()
                }
            }
            .disabled(!vm.isConnected && !vm.hasMCConfCache)
            .tint(.dynetraOrange)
            .confirmationDialog(
                "Apply tire correction?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button(String(format: "Apply %.1f mm", suggested), role: .none) {
                    let result = vm.applyWheelDiameterCorrection(diameterMM: suggested)
                    applyResult = result
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(String(format: "Wheel diameter will change from %.1f mm to %.1f mm. Gear ratio and all other motor settings are unchanged.", currentDiameterMM, suggested))
            }

        } header: {
            Text("Suggested Correction")
        } footer: {
            Label("Only wheel diameter is modified. Gear ratio and motor settings are not touched.", systemImage: "info.circle")
                .font(.caption)
        })
    }

    // MARK: - Result

    private func resultSection(_ result: (success: Bool, message: String)) -> some View {
        Section {
            Label(result.message, systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(result.success ? .green : .orange)

            if result.success {
                Text("Ride at speed again to verify. Target: error < 0.5 km/h. Repeat if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Result")
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, value: String, note: String? = nil) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.system(.body, design: .rounded))
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

#Preview {
    let vm = TelemetryViewModel()
    vm.speedKMH = 28.4
    vm.gpsSpeedKMH = 30.1
    vm.uiSettings.showGPSSpeed = true
    vm.settings.wheelDiameterMM = 241
    vm.settings.motorPolePairs = 7
    vm.settings.gearRatio = 4.5
    return TireSizeCorrectionView(vm: vm)
}

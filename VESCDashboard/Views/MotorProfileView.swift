import SwiftUI

struct MotorProfileView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var maxKMH: String = ""
    @State private var minKMH: String = ""      // positive value; stored as negative ERPM
    @State private var wattMax: String = ""
    @State private var wattMin: String = ""
    @State private var accelPct: String = ""
    @State private var brakePct: String = ""
    @State private var storeToFlash: Bool = true

    private var drivetrain: (polePairs: Float, ratio: Float, wheelMM: Float)? {
        if let dt = vm.drivetrainFromMCCONF(), dt.poles >= 2, dt.wheelDiameterMM > 0 {
            let r = dt.gearRatio == 0 ? 1.0 : dt.gearRatio
            return (Float(dt.poles) / 2.0, r, dt.wheelDiameterMM)
        }
        let s = vm.settings
        guard s.motorPolePairs > 0, s.wheelDiameterMM > 0 else { return nil }
        let r = s.gearRatio == 0 ? 1.0 : s.gearRatio
        return (Float(s.motorPolePairs), Float(r), Float(s.wheelDiameterMM))
    }

    private var hasDrivetrain: Bool { drivetrain != nil }

    private var allValid: Bool {
        guard let ap = Float(accelPct), ap >= 0, ap <= 100,
              let bp = Float(brakePct), bp >= 0, bp <= 100,
              Float(maxKMH).map({ $0 >= 0 }) == true,
              Float(minKMH).map({ $0 >= 0 }) == true,
              hasDrivetrain,
              Float(wattMax).map({ $0 >= 0 }) == true,
              Float(wattMin).map({ $0 <= 0 }) == true
        else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                readSection
                storageSection
                speedSection
                powerSection
                scaleSection
                actionSection
            }
            .navigationTitle(vm.activeVESCLabel.isEmpty ? "Motor Profile" : "Profile · \(vm.activeVESCLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                loadCurrentValues()
                if vm.isConnected && vm.motorLimitsReadState != .reading {
                    vm.fetchMotorConfig()
                }
            }
            .onChange(of: vm.motorLimitsReadState) { state in
                if case .loaded = state { loadCurrentValues() }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Read Section

    private var readSection: some View {
        Section {
            HStack {
                Button {
                    vm.fetchMotorConfig()
                } label: {
                    Label("Read from VESC", systemImage: "arrow.down.circle")
                }
                .disabled(!vm.isConnected || vm.motorLimitsReadState == .reading)
                Spacer()
                switch vm.motorLimitsReadState {
                case .reading:
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.75)
                        Text("Reading…").font(.caption).foregroundStyle(.secondary)
                    }
                case .loaded:
                    Label(vm.hasMCConfCache ? "Full config loaded" : "Loaded",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failed(let msg):
                    Label(msg, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
                case .idle:
                    EmptyView()
                }
            }
        } header: {
            Text(vm.activeVESCLabel.isEmpty ? "VESC" : vm.activeVESCLabel)
        } footer: {
            Text(vm.hasMCConfCache
                 ? "Full config cached — profile write will use COMM_SET_MCCONF."
                 : "Read config first to enable profile write.")
                .font(.caption)
        }
    }

    // MARK: - Storage Mode

    private var storageSection: some View {
        Section {
            Toggle(isOn: $storeToFlash) {
                Label("Save to Flash", systemImage: storeToFlash ? "flame.fill" : "memorychip")
            }
            .tint(.orange)
        } header: {
            Text("Storage Mode")
        } footer: {
            if storeToFlash {
                Text("Flash: all limits saved permanently. Requires reading MCCONF first.")
                    .font(.caption)
            } else {
                Text("RAM: all limits applied until reboot. No MCCONF read required.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Speed Limits

    private var speedSection: some View {
        Section {
            if hasDrivetrain {
                kmhField("Max Forward Speed", placeholder: "50", text: $maxKMH,
                         hint: erpmAnnotation(maxKMH, negative: false))
                kmhField("Max Reverse Speed", placeholder: "20", text: $minKMH,
                         hint: erpmAnnotation(minKMH, negative: true))
            } else {
                Label("Configure drivetrain first (Motor Wizard → Motor Info or Settings → Drivetrain) to set speed limits in km/h.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Speed Limits")
        } footer: {
            Text("Enter both as positive km/h values. Set very high (e.g. 999) to disable the limit.")
                .font(.caption)
        }
    }

    // MARK: - Power Limits

    private var powerSection: some View {
        Section {
            wattField("Max Power", placeholder: "3000", text: $wattMax,
                      hint: "Peak discharge power. Set very high (e.g. 1500000) to disable.")
            wattField("Max Regen", placeholder: "-1500", text: $wattMin,
                      hint: "Peak regenerative braking power (negative). Set very negative to disable.")
            if let wr = Float(wattMin), wr > 0 {
                Label("Regen must be negative", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Power Limits")
        }
    }

    // MARK: - Current Scale

    private var scaleSection: some View {
        Section {
            pctField("Acceleration", placeholder: "100", text: $accelPct,
                     hint: "l_current_max_scale — fraction of peak motor current for acceleration")
            pctField("Braking", placeholder: "100", text: $brakePct,
                     hint: "l_current_min_scale — fraction of peak motor current for braking")
        } header: {
            Text("Current Scale")
        } footer: {
            Text("100% = full rated current. Soft-limits power delivery without changing the hard current limits.")
                .font(.caption)
        }
    }

    // MARK: - Apply

    private var actionSection: some View {
        Section {
            Button { applyAndSend() } label: {
                HStack {
                    Spacer()
                    switch vm.motorLimitsSendState {
                    case .idle:
                        Label(vm.isConnected ? "Apply Profile" : "Connect First",
                              systemImage: "bolt.fill").fontWeight(.semibold)
                    case .sent(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    Spacer()
                }
            }
            .disabled(!vm.isConnected || !allValid || (storeToFlash && !vm.hasMCConfCache))
        } header: {
            Text("Apply")
        } footer: {
            if storeToFlash && !vm.hasMCConfCache {
                Label("Read motor config first to enable flash write.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if storeToFlash {
                Label("Writes permanently to VESC flash. Forwards to all VESCs on CAN.", systemImage: "flame")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("RAM only — all limits applied until reboot. Forwards to all VESCs on CAN automatically.", systemImage: "memorychip")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Conversion

    private func kmhToERPM(_ kmh: Float) -> Float {
        guard let dt = drivetrain else { return kmh }
        let circumM = Float.pi * dt.wheelMM / 1000.0
        return kmh / 3.6 * 60.0 / circumM * dt.ratio * dt.polePairs
    }

    private func erpmToKMH(_ erpm: Float) -> Float {
        guard let dt = drivetrain else { return erpm }
        let circumM = Float.pi * dt.wheelMM / 1000.0
        return abs(erpm) / dt.polePairs / dt.ratio / 60.0 * circumM * 3.6
    }

    private func erpmAnnotation(_ kmhText: String, negative: Bool) -> String {
        guard let kmh = Float(kmhText), kmh > 0 else { return "" }
        let erpm = kmhToERPM(kmh)
        let sign = negative ? "-" : ""
        return "≈ \(sign)\(String(format: "%.0f", erpm)) ERPM"
    }

    // MARK: - Data Binding

    private func loadCurrentValues() {
        let p = vm.motorProfile
        maxKMH   = fmtKMH(erpmToKMH(p.maxERPM))
        minKMH   = fmtKMH(erpmToKMH(p.minERPM))   // minERPM is negative; erpmToKMH takes abs
        wattMax  = fmt(p.wattMax)
        wattMin  = fmt(p.wattMin)
        accelPct = fmt(p.currentMaxScale * 100)
        brakePct = fmt(p.currentMinScale * 100)
    }

    private func applyAndSend() {
        guard let fmax = Float(maxKMH), fmax >= 0,
              let fmin = Float(minKMH), fmin >= 0,
              let wm   = Float(wattMax), wm >= 0,
              let wr   = Float(wattMin), wr <= 0,
              let ap   = Float(accelPct), ap >= 0, ap <= 100,
              let bp   = Float(brakePct), bp >= 0, bp <= 100
        else { return }

        vm.applyProfile(MotorProfile(
            maxERPM:  kmhToERPM(fmax),
            minERPM: -kmhToERPM(fmin),
            wattMax: wm, wattMin: wr,
            currentMaxScale: ap / 100,
            currentMinScale: bp / 100
        ), storeToFlash: storeToFlash)
    }

    private func fmt(_ f: Float) -> String {
        f.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(f)) : String(format: "%.2f", f)
    }

    private func fmtKMH(_ f: Float) -> String {
        String(format: "%.1f", f)
    }

    // MARK: - Field Builders

    @ViewBuilder
    private func kmhField(_ label: String, placeholder: String,
                           text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                HStack(spacing: 4) {
                    TextField(placeholder, text: text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("km/h").foregroundStyle(.secondary).font(.subheadline)
                }
            }
            if !hint.isEmpty {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func wattField(_ label: String, placeholder: String,
                            text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                HStack(spacing: 4) {
                    TextField(placeholder, text: text)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                    Text("W").foregroundStyle(.secondary).font(.subheadline)
                }
            }
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func pctField(_ label: String, placeholder: String,
                           text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                HStack(spacing: 4) {
                    TextField(placeholder, text: text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("%").foregroundStyle(.secondary).font(.subheadline)
                }
            }
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    MotorProfileView(vm: TelemetryViewModel())
}

import SwiftUI

struct MotorProfileEditView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    let existingProfile: MotorProfile?

    @State private var profileName: String = ""
    @State private var maxKMH: String = ""
    @State private var minKMH: String = ""
    @State private var wattMax: String = ""
    @State private var wattMin: String = ""
    @State private var accelPct: String = ""
    @State private var brakePct: String = ""

    private var isEditing: Bool { existingProfile != nil }

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
        guard !profileName.trimmingCharacters(in: .whitespaces).isEmpty,
              let ap = Float(accelPct), ap >= 0, ap <= 100,
              let bp = Float(brakePct), bp >= 0, bp <= 100,
              Float(wattMax).map({ $0 >= 0 }) == true,
              Float(wattMin).map({ $0 <= 0 }) == true
        else { return false }
        if hasDrivetrain {
            guard Float(maxKMH).map({ $0 >= 0 }) == true,
                  Float(minKMH).map({ $0 >= 0 }) == true
            else { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                readSection
                speedSection
                powerSection
                scaleSection
                saveSection
            }
            .navigationTitle(isEditing ? "Edit Profile" : "New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { loadValues() }
            .onChange(of: vm.motorLimitsReadState) { state in
                if case .loaded = state { loadValues() }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Name

    private var nameSection: some View {
        Section {
            TextField("Profile Name", text: $profileName)
        } header: {
            Text("Name")
        }
    }

    // MARK: - Read from VESC

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
            Text("Optional — populates fields from the current VESC limits.")
                .font(.caption)
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
                Label("Configure drivetrain first (Motor Wizard or Settings) to enter speed in km/h.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Speed Limits")
        } footer: {
            Text("Positive values. Set very high (e.g. 999) to disable.")
                .font(.caption)
        }
    }

    // MARK: - Power Limits

    private var powerSection: some View {
        Section {
            wattField("Max Power", placeholder: "3000", text: $wattMax,
                      hint: "Peak discharge power. Set very high (e.g. 1500000) to disable.")
            wattField("Max Regen", placeholder: "-1500", text: $wattMin,
                      hint: "Peak regen power (negative). Set very negative to disable.")
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
                     hint: "l_current_max_scale — fraction of peak motor current")
            pctField("Braking", placeholder: "100", text: $brakePct,
                     hint: "l_current_min_scale — fraction of peak motor current")
        } header: {
            Text("Current Scale")
        } footer: {
            Text("100% = full rated current.")
                .font(.caption)
        }
    }

    // MARK: - Save

    private var saveSection: some View {
        Section {
            Button {
                saveProfile()
            } label: {
                HStack {
                    Spacer()
                    Label(isEditing ? "Save Changes" : "Save Profile",
                          systemImage: "checkmark.circle.fill")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!allValid)
        }
    }

    // MARK: - Conversion

    private func kmhToERPM(_ kmh: Float) -> Float {
        guard let dt = drivetrain else { return kmh }
        let circumM = Float.pi * dt.wheelMM / 1000.0
        return kmh / 3.6 * 60.0 / circumM * dt.ratio * dt.polePairs
    }

    private func erpmToKMH(_ erpm: Float) -> Float {
        guard let dt = drivetrain else { return abs(erpm) }
        let circumM = Float.pi * dt.wheelMM / 1000.0
        return abs(erpm) / dt.polePairs / dt.ratio / 60.0 * circumM * 3.6
    }

    private func erpmAnnotation(_ kmhText: String, negative: Bool) -> String {
        guard let kmh = Float(kmhText), kmh > 0 else { return "" }
        let erpm = kmhToERPM(kmh)
        return "≈ \(negative ? "-" : "")\(String(format: "%.0f", erpm)) ERPM"
    }

    // MARK: - Data

    private func loadValues() {
        let p = existingProfile ?? vm.motorProfile
        profileName = existingProfile?.name ?? ""
        maxKMH      = fmtKMH(erpmToKMH(p.maxERPM))
        minKMH      = fmtKMH(erpmToKMH(p.minERPM))
        wattMax     = fmt(p.wattMax)
        wattMin     = fmt(p.wattMin)
        accelPct    = fmt(p.currentMaxScale * 100)
        brakePct    = fmt(p.currentMinScale * 100)
    }

    private func saveProfile() {
        guard let wm = Float(wattMax), wm >= 0,
              let wr = Float(wattMin), wr <= 0,
              let ap = Float(accelPct), ap >= 0, ap <= 100,
              let bp = Float(brakePct), bp >= 0, bp <= 100
        else { return }

        var profile = existingProfile ?? MotorProfile()
        profile.name = profileName.trimmingCharacters(in: .whitespaces)
        profile.wattMax = wm
        profile.wattMin = wr
        profile.currentMaxScale = ap / 100
        profile.currentMinScale = bp / 100

        if hasDrivetrain,
           let fmax = Float(maxKMH), fmax >= 0,
           let fmin = Float(minKMH), fmin >= 0 {
            profile.maxERPM =  kmhToERPM(fmax)
            profile.minERPM = -kmhToERPM(fmin)
        }

        if isEditing { vm.updateProfile(profile) } else { vm.addProfile(profile) }
        dismiss()
    }

    private func fmt(_ f: Float) -> String {
        guard f.isFinite, f >= Float(Int.min), f <= Float(Int.max) else { return String(format: "%.2f", f) }
        return f.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(f)) : String(format: "%.2f", f)
    }

    private func fmtKMH(_ f: Float) -> String { String(format: "%.1f", f) }

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
    MotorProfileEditView(vm: TelemetryViewModel(), existingProfile: nil)
}

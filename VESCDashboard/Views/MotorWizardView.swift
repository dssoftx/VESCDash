import SwiftUI

// MARK: - Motor Type

enum MotorType: String, CaseIterable {
    case inrunner  = "Inrunner"
    case outrunner = "Outrunner"
    case hub       = "Hub Motor"
    case ebikeDD   = "Ebike Direct Drive"

    var icon: String {
        switch self {
        case .inrunner:  return "circle.circle"
        case .outrunner: return "circle.circle.fill"
        case .hub:       return "bicycle"
        case .ebikeDD:   return "bolt.fill"
        }
    }

    var hint: String {
        switch self {
        case .inrunner:  return "Shaft spins inside the stator. Typical for drones, RC cars."
        case .outrunner: return "Bell/rotor spins around the outside. Common for eskate, EUC."
        case .hub:       return "Motor integrated into wheel hub. Direct drive."
        case .ebikeDD:   return "Mid-drive or geared ebike motor with chain/belt drivetrain."
        }
    }
}

// MARK: - Wizard Steps

private enum WizardStep: Int, CaseIterable {
    case motorInfo = 0
    case detection = 1
}

// MARK: - MotorWizardView

struct MotorWizardView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: WizardStep = .motorInfo

    // Step 1 — Motor & Drivetrain
    @State private var motorType: MotorType = .outrunner
    @State private var totalPoles: String = "14"          // total poles (not pairs)
    @State private var gearRatio: String = "0"            // 0 = direct drive
    @State private var wheelDiameterMM: String = "83"
    @State private var detectionCurrent: String = ""

    // Step 2 — Detection
    @State private var showSpinWarning = false
    @State private var tc_µs: String = "1000"             // current controller time constant

    // Computed
    private var polesInt: Int { Int(totalPoles) ?? 14 }
    private var gearRatioF: Float { Float(gearRatio) ?? 0 }
    private var wheelF: Float { Float(wheelDiameterMM) ?? 83 }
    private var detCurrent: Float { Float(detectionCurrent) ?? max(1, vm.motorLimits.phaseCurrentMax / 3) }
    private var tcF: Float { Float(tc_µs) ?? 1000 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepIndicator
                Divider()

                switch step {
                case .motorInfo: motorInfoStep
                case .detection: detectionStep
                }
            }
            .navigationTitle("Motor Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // Default detection current to 1/3 of phase max
                if detectionCurrent.isEmpty {
                    let def = max(1, vm.motorLimits.phaseCurrentMax / 3)
                    detectionCurrent = String(format: "%.0f", def)
                }
                // Auto-populate drivetrain from MCCONF if cached
                if let dt = vm.drivetrainFromMCCONF() {
                    totalPoles = "\(dt.poles)"
                    gearRatio  = fmtF(dt.gearRatio)
                    wheelDiameterMM = fmtF(dt.wheelDiameterMM)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(WizardStep.allCases, id: \.rawValue) { s in
                let active = s.rawValue <= step.rawValue
                VStack(spacing: 4) {
                    Circle()
                        .fill(active ? Color.cyan : Color.gray.opacity(0.3))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Text("\(s.rawValue + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(active ? .black : .secondary)
                        )
                    Text(s == .motorInfo ? "Motor Info" : "Detection")
                        .font(.caption2)
                        .foregroundStyle(active ? .cyan : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 24)
    }

    // MARK: - Step 1: Motor Info

    private var motorInfoStep: some View {
        Form {
            Section {
                ForEach(MotorType.allCases, id: \.self) { mt in
                    Button {
                        motorType = mt
                    } label: {
                        HStack {
                            Label(mt.rawValue, systemImage: mt.icon)
                                .foregroundStyle(.primary)
                            Spacer()
                            if motorType == mt {
                                Image(systemName: "checkmark").foregroundStyle(.cyan)
                            }
                        }
                    }
                }
            } header: {
                Text("Motor Type")
            } footer: {
                Text(motorType.hint).font(.caption)
            }

            Section {
                LabeledContent("Total Poles") {
                    TextField("14", text: $totalPoles)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                if let p = Int(totalPoles), p > 0 {
                    Text("\(p) poles = \(p/2) pole pairs")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Motor Poles")
            } footer: {
                Text("Total number of motor poles — always even. Count the magnets on the rotor, or use poles = pole_pairs × 2.")
                    .font(.caption)
            }

            Section {
                LabeledContent("Gear Ratio") {
                    TextField("0", text: $gearRatio)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Wheel Diameter") {
                    HStack(spacing: 4) {
                        TextField("83", text: $wheelDiameterMM)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("mm").foregroundStyle(.secondary).font(.subheadline)
                    }
                }
                if vm.hasMCConfCache {
                    Button {
                        if let dt = vm.drivetrainFromMCCONF() {
                            totalPoles = "\(dt.poles)"
                            gearRatio  = fmtF(dt.gearRatio)
                            wheelDiameterMM = fmtF(dt.wheelDiameterMM)
                        }
                    } label: {
                        Label("Read Drivetrain from VESC", systemImage: "arrow.down.circle")
                    }
                }
            } header: {
                Text("Drivetrain")
            } footer: {
                Text("Gear ratio 0 = direct drive / hub motor. Wheel diameter sets the speed calculation.")
                    .font(.caption)
            }

            Section {
                Button {
                    withAnimation { step = .detection }
                } label: {
                    HStack {
                        Spacer()
                        Text("Next: FOC Detection")
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.right")
                        Spacer()
                    }
                }
                .disabled(polesInt < 2)
            }
        }
    }

    // MARK: - Step 2: Detection

    private var detectionStep: some View {
        Form {
            Section {
                ampField("Detection Current", placeholder: "10", text: $detectionCurrent,
                         hint: "Recommended: motor phase max ÷ 3  (currently ~\(Int(vm.motorLimits.phaseCurrentMax/3)) A)")
                LabeledContent("Time Constant") {
                    HStack(spacing: 4) {
                        TextField("1000", text: $tc_µs)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("µs").foregroundStyle(.secondary).font(.subheadline)
                    }
                }
            } header: {
                Text("Detection Parameters")
            } footer: {
                Text("Time constant tunes the current controller bandwidth. 1000 µs is a safe default for most motors.")
                    .font(.caption)
            }

            // RL Measurement
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Step 1 — Measure R & L")
                            .fontWeight(.medium)
                        Text("Motor makes noise but will not rotate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        vm.detectionState = .idle
                        vm.measureRL()
                    } label: {
                        Text("Measure")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isConnected || isDetecting)
                }

                rlResultRow
            }

            // Flux Linkage Measurement
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Step 2 — Measure Flux Linkage")
                            .fontWeight(.medium)
                        Text("Motor will spin up. Clear the area.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button {
                        showSpinWarning = true
                    } label: {
                        Text("Measure")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isConnected || !rlDone || isDetecting)
                    .alert("Motor Will Spin", isPresented: $showSpinWarning) {
                        Button("Cancel", role: .cancel) {}
                        Button("Start", role: .destructive) {
                            vm.measureFluxLinkageOpenloop(current: detCurrent)
                        }
                    } message: {
                        Text("The motor will spin up during flux linkage measurement. Make sure nothing is in the way of the motor or drivetrain before proceeding.")
                    }
                }

                lambdaResultRow
            }

            detectionResultSections

            Section {
                Button {
                    withAnimation { step = .motorInfo }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var detectionResultSections: some View {
        if case .complete(let r, let l, let ldLq, let lambda) = vm.detectionState {
            let bw      = Float(1.0 / (tcF * 1e-6))
            let l_H     = l / 1_000_000
            let kp      = l_H * bw
            let ki      = r * bw
            let obsgain = Float(1e3 / (lambda * lambda))

            Section {
                resultRow("KP",            value: String(format: "%.4f", kp))
                resultRow("KI",            value: String(format: "%.4f", ki))
                resultRow("Observer Gain", value: String(format: "%.0f", obsgain))
            } header: {
                Text("Calculated Controller Values")
            } footer: {
                Text("Calculated from R, L, λ and the time constant. Written to VESC on apply.")
                    .font(.caption)
            }

            Section {
                sendStateRow
                Button {
                    vm.applyFOCDetection(
                        r_Ω: r, l_µH: l, ldLqDiff_µH: ldLq, lambda_Wb: lambda, tc_µs: tcF,
                        siMotorPoles: polesInt, siGearRatio: gearRatioF, siWheelDiameterMM: wheelF
                    )
                } label: {
                    HStack {
                        Spacer()
                        Label("Apply All to VESC", systemImage: "bolt.fill").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!vm.isConnected || !vm.hasMCConfCache)
            } header: {
                Text("Apply")
            } footer: {
                if !vm.hasMCConfCache {
                    Label("Read motor config first (Motor Config → Read from VESC) to enable full config write.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Label("Saves R, L, λ, KP, KI, observer gain, poles, gear ratio, and wheel diameter to VESC flash.",
                          systemImage: "flame")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var rlResultRow: some View {
        Group {
            if case .measuringRL = vm.detectionState {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Measuring…").foregroundStyle(.secondary).font(.caption)
                }
            } else if let rl = extractRL(vm.detectionState) {
                VStack(alignment: .leading, spacing: 4) {
                    resultRow("Resistance", value: String(format: "%.3f mΩ", rl.r * 1000))
                    resultRow("Inductance", value: String(format: "%.2f µH",  rl.l))
                    resultRow("Ld-Lq Diff", value: String(format: "%.2f µH",  rl.ldLq))
                }
            } else if case .failed(let msg) = vm.detectionState {
                Label(msg, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
            } else {
                Text("Not measured yet").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var lambdaResultRow: some View {
        Group {
            if case .measuringLinkage = vm.detectionState {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Spinning motor…").foregroundStyle(.secondary).font(.caption)
                }
            } else if case .complete(_, _, _, let lambda) = vm.detectionState {
                resultRow("Flux Linkage λ", value: String(format: "%.4f mWb", lambda * 1000))
            } else if case .failed(let msg) = vm.detectionState, !msg.contains("R/L") {
                Label(msg, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
            } else {
                Text(rlDone ? "Ready — tap Measure" : "Run R/L first")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var sendStateRow: some View {
        Group {
            switch vm.motorLimitsSendState {
            case .sent(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func ampField(_ label: String, placeholder: String,
                           text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                HStack(spacing: 4) {
                    TextField(placeholder, text: text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("A").foregroundStyle(.secondary).font(.subheadline)
                }
            }
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private var isDetecting: Bool {
        switch vm.detectionState {
        case .measuringRL, .measuringLinkage: return true
        default: return false
        }
    }

    private var rlDone: Bool {
        switch vm.detectionState {
        case .rlResult, .measuringLinkage, .complete: return true
        default: return false
        }
    }

    private func fmtF(_ v: Float) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.3g", v)
    }

    private func extractRL(_ state: WizardDetectionState) -> (r: Float, l: Float, ldLq: Float)? {
        switch state {
        case .rlResult(let r, let l, let ldLq):        return (r, l, ldLq)
        case .measuringLinkage(let r, let l, let ldLq): return (r, l, ldLq)
        case .complete(let r, let l, let ldLq, _):     return (r, l, ldLq)
        default: return nil
        }
    }
}

#Preview {
    MotorWizardView(vm: TelemetryViewModel())
}

import SwiftUI

struct MotorConfigView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var battMax: String = ""
    @State private var battRegen: String = ""
    @State private var phaseMax: String = ""
    @State private var absMax: String = ""
    @State private var storeToFlash = false

    private var allValid: Bool {
        guard
            let bm = Float(battMax),  bm > 0,
            let br = Float(battRegen), br <= 0,
            let pm = Float(phaseMax), pm > 0,
            let am = Float(absMax),   am > 0
        else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                readSection
                batterySection
                phaseSection
                actionSection
            }
            .navigationTitle("Motor Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                loadCurrentValues()
                // Auto-read from VESC when the view opens and we're connected
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
                    Label("Loaded", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failed(let msg):
                    Label(msg, systemImage: "xmark.circle")
                        .font(.caption).foregroundStyle(.red)
                case .idle:
                    EmptyView()
                }
            }
        } header: {
            Text("Current VESC Values")
        } footer: {
            Text(vm.isConnected
                 ? "Reads l_current_max, l_in_current_max, l_in_current_min and l_abs_current_max from the active VESC."
                 : "Connect to a VESC to read its current limits.")
                .font(.caption)
        }
    }

    // MARK: - Battery Section

    private var batterySection: some View {
        Section {
            currentField("Max Battery Amps", placeholder: "40", text: $battMax,
                         hint: "Current drawn from pack while accelerating (positive)")
            currentField("Max Regen Amps", placeholder: "-12", text: $battRegen,
                         hint: "Current returned to pack while braking (negative, e.g. -12)")

            if let br = Float(battRegen), br > 0 {
                Label("Regen must be negative (e.g. -12)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Battery Limits")
        } footer: {
            Text("Regen is negative because current flows back into the pack.")
                .font(.caption)
        }
    }

    // MARK: - Phase Section

    private var phaseSection: some View {
        Section {
            currentField("Max Phase Current", placeholder: "60", text: $phaseMax,
                         hint: "Peak current through motor windings (positive)")
            currentField("Max Absolute Current", placeholder: "130", text: $absMax,
                         hint: "Hard cutoff — motor shuts off if exceeded")
        } header: {
            Text("Motor Limits")
        } footer: {
            Text("Absolute current should be higher than phase current — it's a safety stop, not a normal operating limit.")
                .font(.caption)
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        Section {
            Toggle(isOn: $storeToFlash) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save to VESC Flash")
                    Text("Persists after power cycle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.orange)

            Button { applyAndSend() } label: {
                HStack {
                    Spacer()
                    switch vm.motorLimitsSendState {
                    case .idle:
                        Label(vm.isConnected ? "Send to VESC" : "Connect First",
                              systemImage: "bolt.fill")
                    case .sent(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
            }
            .disabled(!vm.isConnected || !allValid)

        } header: {
            Text("Apply")
        } footer: {
            if storeToFlash {
                Label("Flash write is permanent. Verify values are safe for your motor.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Without \"Save to Flash\", limits reset to VESC defaults on next power cycle.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func currentField(_ label: String, placeholder: String,
                               text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                HStack(spacing: 4) {
                    TextField(placeholder, text: text)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                    Text("A").foregroundStyle(.secondary).font(.subheadline)
                }
            }
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func loadCurrentValues() {
        battMax   = fmt(vm.motorLimits.batteryCurrentMax)
        battRegen = fmt(vm.motorLimits.batteryCurrentRegen)
        phaseMax  = fmt(vm.motorLimits.phaseCurrentMax)
        absMax    = fmt(vm.motorLimits.absCurrentMax)
    }

    private func applyAndSend() {
        guard let bm = Float(battMax),  bm > 0,
              let br = Float(battRegen), br <= 0,
              let pm = Float(phaseMax), pm > 0,
              let am = Float(absMax),   am > 0 else { return }

        vm.motorLimits.batteryCurrentMax   = bm
        vm.motorLimits.batteryCurrentRegen = br
        vm.motorLimits.phaseCurrentMax     = pm
        vm.motorLimits.absCurrentMax       = am

        vm.sendMotorLimits(storeToFlash: storeToFlash)
    }

    private func fmt(_ f: Float) -> String {
        f.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(f)) : String(f)
    }
}

#Preview {
    MotorConfigView(vm: TelemetryViewModel())
}

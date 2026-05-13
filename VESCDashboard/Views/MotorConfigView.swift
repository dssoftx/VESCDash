import SwiftUI
import UIKit

struct MotorConfigView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var copiedWarning = false

    // Current limits
    @State private var battMax: String = ""
    @State private var battRegen: String = ""
    @State private var phaseMax: String = ""
    @State private var phaseRegen: String = ""
    @State private var absMax: String = ""

    // FOC settings
    @State private var observerType: Int = 3
    @State private var zeroVectorFreq: String = ""
    @State private var fwCurrentMax: String = ""
    @State private var fwDutyStart: String = ""

    @State private var storeToFlash = false

    private var allValid: Bool {
        guard
            let bm = Float(battMax),     bm > 0,
            let br = Float(battRegen),   br <= 0,
            let pm = Float(phaseMax),    pm > 0,
            let pr = Float(phaseRegen),  pr <= 0,
            let am = Float(absMax),      am > 0,
            let fz = Float(zeroVectorFreq), fz > 0,
            let fw = Float(fwCurrentMax), fw >= 0,
            let fd = Float(fwDutyStart), fd >= 0, fd <= 1
        else { return false }
        return true
    }

    private var isLocked: Bool { vm.mcconfCompatWarning != nil || vm.fwMCConfBlocked }

    var body: some View {
        NavigationStack {
            Form {
                if vm.fwMCConfBlocked {
                    fwBlockedSection
                } else if let warning = vm.mcconfCompatWarning {
                    compatWarningSection(warning)
                }
                readSection
                batterySection
                    .disabled(isLocked)
                phaseSection
                    .disabled(isLocked)
                focSection
                    .disabled(isLocked)
                actionSection
                    .disabled(isLocked)
            }
            .navigationTitle(vm.activeVESCLabel.isEmpty ? "Motor Config" : "Motor Config · \(vm.activeVESCLabel)")
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

    // MARK: - Firmware Version Block Banner

    private var fwBlockedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Firmware Not Supported", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.red)

                if let v = vm.localFWVersion {
                    Text("Your VESC is running firmware **\(v)**.")
                        .font(.caption)
                }

                let allowed = VESCProtocolParser.allowedFirmwareVersions
                    .sorted()
                    .map { v in "\(v / 100).\(String(format: "%02d", v % 100))" }
                    .joined(separator: ", ")
                Text("Motor config writes and FOC detection are only allowed on supported firmware (\(allowed)). Use VESC Tool to update your firmware or configure this VESC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Motor **profiles** (current scale, speed limits) still work on any firmware via the Profiles screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Unsupported Firmware")
        }
    }

    // MARK: - Compat Warning Banner

    private func compatWarningSection(_ warning: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Firmware Layout Mismatch", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text("The MCCONF byte offsets used by this app (firmware 6.05) do not match the firmware on your VESC. All config fields are locked to prevent writing corrupt data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(warning)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(Color(.systemGray6).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    UIPasteboard.general.string = warning
                    copiedWarning = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedWarning = false }
                } label: {
                    Label(copiedWarning ? "Copied!" : "Copy Report", systemImage: copiedWarning ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(copiedWarning ? .green : .orange)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Compatibility")
        }
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
                    Label(msg, systemImage: "xmark.circle")
                        .font(.caption).foregroundStyle(.red)
                case .idle:
                    EmptyView()
                }
            }
        } header: {
            Text(vm.activeVESCLabel.isEmpty ? "VESC" : vm.activeVESCLabel)
        } footer: {
            if vm.hasMCConfCache {
                Text("Full config cached — Send will use COMM_SET_MCCONF (flash write). All settings including observer and field weakening will apply.")
                    .font(.caption)
            } else {
                Text(vm.isConnected
                     ? "Read config to enable observer and field weakening settings. Without cache, only current limits can be sent (COMM_SET_MCCONF_TEMP)."
                     : "Connect to a VESC to read its motor config.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Battery Section

    private var batterySection: some View {
        Section {
            ampField("Max Battery Amps",   placeholder: "40",  text: $battMax,
                     hint: "Current drawn from pack while accelerating")
            ampField("Max Battery Regen",  placeholder: "-12", text: $battRegen,
                     hint: "Current returned to pack while braking (negative, e.g. -12)")
            if let br = Float(battRegen), br > 0 {
                Label("Battery regen must be negative", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Battery Limits")
        }
    }

    // MARK: - Phase Section

    private var phaseSection: some View {
        Section {
            ampField("Max Phase Current",  placeholder: "60",  text: $phaseMax,
                     hint: "Peak current through motor windings")
            ampField("Max Phase Regen",    placeholder: "-60", text: $phaseRegen,
                     hint: "Phase braking current limit (negative, e.g. -60)")
            ampField("Max Absolute Current", placeholder: "130", text: $absMax,
                     hint: "Hard cutoff — motor shuts off if exceeded")
            if let pr = Float(phaseRegen), pr > 0 {
                Label("Phase regen must be negative", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Motor Limits")
        }
    }

    // MARK: - FOC Section

    private var focSection: some View {
        Section {
            Picker("Observer Type", selection: $observerType) {
                ForEach(0..<MotorLimitsConfig.observerNames.count, id: \.self) { i in
                    Text(MotorLimitsConfig.observerNames[i]).tag(i)
                }
            }

            LabeledContent("Zero Vector Freq") {
                HStack(spacing: 4) {
                    TextField("30000", text: $zeroVectorFreq)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                    Text("Hz").foregroundStyle(.secondary).font(.subheadline)
                }
            }

            ampField("Field Weakening Current", placeholder: "0", text: $fwCurrentMax,
                     hint: "Max FW current (A). 0 = field weakening disabled")

            LabeledContent("FW Duty Start") {
                HStack(spacing: 4) {
                    TextField("0.90", text: $fwDutyStart)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("0–1").foregroundStyle(.secondary).font(.subheadline)
                }
            }
        } header: {
            Text("FOC Settings")
        } footer: {
            if !vm.hasMCConfCache {
                Label("Read config first to apply FOC settings.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Observer type, FW settings, and zero vector frequency will be written on Send.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        Section {
            if !vm.hasMCConfCache {
                Toggle(isOn: $storeToFlash) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save to VESC Flash")
                        Text("Persists after power cycle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)
            }

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
            if vm.hasMCConfCache {
                Label("Full config write — always saves to flash.", systemImage: "flame")
                    .font(.caption).foregroundStyle(.orange)
            } else if storeToFlash {
                Label("Flash write is permanent. Verify values are safe for your motor.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Without \"Save to Flash\", current limits reset to VESC defaults on next power cycle. FOC settings require Read + flash write.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func ampField(_ label: String, placeholder: String,
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
        battMax      = fmt(vm.motorLimits.batteryCurrentMax)
        battRegen    = fmt(vm.motorLimits.batteryCurrentRegen)
        phaseMax     = fmt(vm.motorLimits.phaseCurrentMax)
        phaseRegen   = fmt(vm.motorLimits.phaseCurrentRegen)
        absMax       = fmt(vm.motorLimits.absCurrentMax)
        observerType = vm.motorLimits.observerType
        zeroVectorFreq  = fmt(vm.motorLimits.zeroVectorFreqHz)
        fwCurrentMax    = fmt(vm.motorLimits.fieldWeakeningCurrentMax)
        fwDutyStart     = fmtDuty(vm.motorLimits.fieldWeakeningDutyStart)
    }

    private func applyAndSend() {
        guard
            let bm = Float(battMax),     bm > 0,
            let br = Float(battRegen),   br <= 0,
            let pm = Float(phaseMax),    pm > 0,
            let pr = Float(phaseRegen),  pr <= 0,
            let am = Float(absMax),      am > 0,
            let fz = Float(zeroVectorFreq), fz > 0,
            let fw = Float(fwCurrentMax), fw >= 0,
            let fd = Float(fwDutyStart), fd >= 0, fd <= 1
        else { return }

        vm.motorLimits.batteryCurrentMax         = bm
        vm.motorLimits.batteryCurrentRegen       = br
        vm.motorLimits.phaseCurrentMax           = pm
        vm.motorLimits.phaseCurrentRegen         = pr
        vm.motorLimits.absCurrentMax             = am
        vm.motorLimits.observerType              = observerType
        vm.motorLimits.zeroVectorFreqHz          = fz
        vm.motorLimits.fieldWeakeningCurrentMax  = fw
        vm.motorLimits.fieldWeakeningDutyStart   = fd

        vm.sendMotorLimits(storeToFlash: storeToFlash)
    }

    private func fmt(_ f: Float) -> String {
        guard f.isFinite, f >= Float(Int.min), f <= Float(Int.max) else { return String(format: "%.2f", f) }
        return f.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(f)) : String(f)
    }

    private func fmtDuty(_ f: Float) -> String {
        String(format: "%.2f", f)
    }
}

#Preview {
    MotorConfigView(vm: TelemetryViewModel())
}

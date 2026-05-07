import SwiftUI

struct MotorProfileListView: View {
    @ObservedObject var vm: TelemetryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAddProfile = false
    @State private var editingProfile: MotorProfile? = nil

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

    private func erpmToKMH(_ erpm: Float) -> Float? {
        guard let dt = drivetrain else { return nil }
        let circumM = Float.pi * dt.wheelMM / 1000.0
        return abs(erpm) / dt.polePairs / dt.ratio / 60.0 * circumM * 3.6
    }

    private func subtitle(for p: MotorProfile) -> String {
        var parts: [String] = []
        if let fwd = erpmToKMH(p.maxERPM) {
            parts.append("↑\(String(format: "%.0f", fwd)) km/h")
        }
        if let rev = erpmToKMH(p.minERPM) {
            parts.append("↓\(String(format: "%.0f", rev)) km/h")
        }
        if p.wattMax < 999_999 {
            parts.append("\(String(format: "%.0f", p.wattMax)) W")
        }
        let scale = Int((min(p.currentMaxScale, p.currentMinScale) * 100).rounded())
        parts.append("\(scale)%")
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if vm.savedProfiles.isEmpty {
                    emptyState
                } else {
                    List {
                        statusRow
                        ForEach(vm.savedProfiles) { profile in
                            profileRow(profile)
                        }
                        .onDelete { offsets in
                            offsets.map { vm.savedProfiles[$0].id }.forEach { vm.removeProfile(id: $0) }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Motor Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddProfile = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddProfile) {
            MotorProfileEditView(vm: vm, existingProfile: nil)
        }
        .sheet(item: $editingProfile) { profile in
            MotorProfileEditView(vm: vm, existingProfile: profile)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Status row (apply feedback)

    @ViewBuilder
    private var statusRow: some View {
        switch vm.motorLimitsSendState {
        case .sent(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
                .listRowBackground(Color.green.opacity(0.1))
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)
                .listRowBackground(Color.red.opacity(0.1))
        default:
            EmptyView()
        }
    }

    // MARK: - Profile row

    private func profileRow(_ profile: MotorProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.name)
                .font(.body.weight(.semibold))
            let sub = subtitle(for: profile)
            if !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                pillButton("Edit", icon: "pencil", color: .primary) {
                    editingProfile = profile
                }
                pillButton("RAM", icon: "memorychip", color: .blue) {
                    vm.applyProfile(profile, storeToFlash: false)
                }
                .opacity(vm.isConnected ? 1 : 0.4)
                .disabled(!vm.isConnected)

                pillButton("Flash", icon: "flame.fill", color: .orange) {
                    vm.applyProfile(profile, storeToFlash: true)
                }
                .opacity(vm.isConnected ? 1 : 0.4)
                .disabled(!vm.isConnected)

                Spacer()
            }
        }
        .padding(.vertical, 6)
    }

    private func pillButton(_ label: String, icon: String, color: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No Profiles Yet")
                .font(.title3.weight(.semibold))
            Text("Tap + to create your first motor profile.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showAddProfile = true } label: {
                Label("New Profile", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(32)
    }
}

#Preview {
    let vm = TelemetryViewModel()
    vm.savedProfiles = [
        MotorProfile(id: UUID(), name: "Eco", maxERPM: 50000, minERPM: -20000,
                     wattMax: 1500, wattMin: -1000, currentMaxScale: 0.6, currentMinScale: 0.6),
        MotorProfile(id: UUID(), name: "Sport", maxERPM: 100000, minERPM: -50000,
                     wattMax: 5000, wattMin: -3000, currentMaxScale: 1.0, currentMinScale: 1.0),
    ]
    return MotorProfileListView(vm: vm)
}

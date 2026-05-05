import SwiftUI
import CoreBluetooth

struct DeviceScanView: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                if bleManager.discoveredDevices.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .navigationTitle("Find VESC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        bleManager.stopScanning()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if bleManager.connectionState == .scanning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button("Scan") { bleManager.startScanning() }
                            .disabled(!bleManager.isBluetoothReady)
                    }
                }
            }
            .onAppear { bleManager.startScanning() }
            .onDisappear { bleManager.stopScanning() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 20) {
            if bleManager.connectionState == .scanning {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.cyan)
                Text("Searching for VESC devices…")
                    .foregroundStyle(.secondary)
            } else if !bleManager.isBluetoothReady {
                Image(systemName: "bluetooth.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Bluetooth Unavailable")
                    .font(.headline)
                Text("Enable Bluetooth in Settings to connect to your VESC.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No Devices Found")
                    .font(.headline)
                Text("Make sure your VESC is powered on and BLE is enabled.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                Button("Scan Again") { bleManager.startScanning() }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
            }
        }
    }

    private var deviceList: some View {
        List(bleManager.discoveredDevices) { device in
            Button {
                bleManager.connect(to: device)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                            .font(.headline)
                        Text(device.id.uuidString.prefix(18) + "…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospaced()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Image(systemName: device.signalStrengthIcon)
                            .foregroundStyle(.cyan)
                        Text("\(device.rssi) dBm")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
    }
}

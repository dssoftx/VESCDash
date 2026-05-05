import SwiftUI

struct DashboardView: View {
    @ObservedObject var vm: TelemetryViewModel
    @State private var showSettings = false
    @State private var showMotorConfig = false
    @State private var showLog = false
    @State private var showScan = false

    private var t: TelemetryData { vm.telemetry }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    speedGauge
                    topMetrics
                    temperatureRow
                    currentRow
                    dutyCycleBar
                    if t.hasFault { faultBanner }
                    statsRow
                    peakStatsRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("VESC Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    connectionButton
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showLog = true } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        Button { showMotorConfig = true } label: {
                            Image(systemName: "bolt.circle")
                        }
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showScan) {
                DeviceScanView(bleManager: vm.bleManager)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(vm: vm)
            }
            .sheet(isPresented: $showMotorConfig) {
                MotorConfigView(vm: vm)
            }
            .sheet(isPresented: $showLog) {
                LogView(logs: vm.logs)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Speed Gauge

    private var speedGauge: some View {
        ZStack {
            // Background arc
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(.white.opacity(0.06), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: 220, height: 220)

            // Speed arc
            let fraction = min(1.0, abs(vm.speedKMH) / 60.0)
            Circle()
                .trim(from: 0.15, to: 0.15 + 0.7 * fraction)
                .stroke(
                    LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
                .frame(width: 220, height: 220)
                .animation(.easeInOut(duration: 0.15), value: fraction)

            // Center readout
            VStack(spacing: 2) {
                Text(String(format: "%.1f", vm.speedKMH))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: vm.speedKMH < 0))
                    .animation(.easeInOut(duration: 0.15), value: vm.speedKMH)

                Text("km/h")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(t.rpm) ERPM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: t.rpm)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Voltage + Current Row

    private var topMetrics: some View {
        HStack(spacing: 12) {
            MetricCard(
                label: "Voltage",
                value: String(format: "%.1f", t.inputVoltage),
                unit: "V",
                accentColor: .green,
                icon: "bolt.fill",
                warningThreshold: 36.0,
                currentValue: Double(t.inputVoltage)
            )
            MetricCard(
                label: "Battery A",
                value: String(format: "%.1f", t.batteryCurrent),
                unit: "A",
                accentColor: .yellow,
                icon: "battery.100"
            )
        }
    }

    // MARK: - Temperature Row

    private var temperatureRow: some View {
        HStack(spacing: 12) {
            MetricCard(
                label: "FET Temp",
                value: String(format: "%.1f", t.mosfetTemperature),
                unit: "°C",
                accentColor: .orange,
                icon: "thermometer.medium",
                warningThreshold: 80,
                currentValue: Double(t.mosfetTemperature)
            )
            MetricCard(
                label: "Motor Temp",
                value: String(format: "%.1f", t.motorTemperature),
                unit: "°C",
                accentColor: .orange,
                icon: "thermometer.high",
                warningThreshold: 100,
                currentValue: Double(t.motorTemperature)
            )
        }
    }

    // MARK: - Current Row

    private var currentRow: some View {
        HStack(spacing: 12) {
            MetricCard(
                label: "Motor A",
                value: String(format: "%.1f", t.motorCurrent),
                unit: "A",
                accentColor: .cyan,
                icon: "bolt.ring.closed"
            )
            MetricCard(
                label: "Power",
                value: String(format: "%.0f", t.inputVoltage * t.batteryCurrent),
                unit: "W",
                accentColor: .purple,
                icon: "flame.fill"
            )
        }
    }

    // MARK: - Duty Cycle Bar

    private var dutyCycleBar: some View {
        BarMetricCard(
            label: "Duty Cycle",
            value: Double(t.dutyCycle),
            displayText: String(format: "%.1f%%", t.dutyCycle * 100),
            accentColor: .cyan,
            icon: "gauge.with.needle"
        )
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 12) {
            MetricCard(
                label: "Wh Used",
                value: String(format: "%.2f", t.wattHours),
                unit: "Wh",
                accentColor: .indigo,
                icon: "chart.line.downtrend.xyaxis"
            )
            MetricCard(
                label: "Ah Used",
                value: String(format: "%.3f", t.ampHours),
                unit: "Ah",
                accentColor: .teal,
                icon: "minus.forwardslash.plus"
            )
        }
    }

    // MARK: - Peak Stats

    private var peakStatsRow: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Session Peak", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    vm.resetPeakStats()
                } label: {
                    Text("Reset")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)

            HStack(spacing: 12) {
                MetricCard(
                    label: "Top Speed",
                    value: String(format: "%.1f", vm.peakSpeedKMH),
                    unit: "km/h",
                    accentColor: .cyan,
                    icon: "speedometer"
                )
                MetricCard(
                    label: "Peak Power",
                    value: String(format: "%.0f", vm.peakPowerW),
                    unit: "W",
                    accentColor: .purple,
                    icon: "bolt.fill"
                )
                MetricCard(
                    label: "Peak Motor A",
                    value: String(format: "%.1f", vm.peakMotorCurrentA),
                    unit: "A",
                    accentColor: .orange,
                    icon: "bolt.ring.closed"
                )
            }
        }
    }

    // MARK: - Fault Banner

    private var faultBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(t.faultDescription)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(14)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.red.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Connection Button

    private var connectionButton: some View {
        Button {
            if vm.isConnected {
                vm.bleManager.disconnect()
            } else {
                showScan = true
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.isConnected ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(vm.isConnected ? vm.activeVESCLabel : "Connect")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let vm = TelemetryViewModel()
    vm.telemetry = {
        var t = TelemetryData()
        t.mosfetTemperature = 42.5
        t.motorTemperature = 65.3
        t.motorCurrent = 28.4
        t.batteryCurrent = 22.1
        t.rpm = 12500
        t.inputVoltage = 41.8
        t.dutyCycle = 0.58
        t.wattHours = 1.24
        t.ampHours = 0.031
        return t
    }()
    vm.speedKMH = 32.4
    return DashboardView(vm: vm)
}

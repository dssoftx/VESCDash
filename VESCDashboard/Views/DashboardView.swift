import SwiftUI

struct DashboardView: View {
    @ObservedObject var vm: TelemetryViewModel
    @State private var showSettings = false
    @State private var showMotorConfig = false
    @State private var showMotorProfile = false
    @State private var showLog = false
    @State private var showScan = false
    @State private var showMotorWizard = false
    @State private var showUISettings = false

    private var t: TelemetryData { vm.telemetry }
    private var ui: UISettings { vm.uiSettings }

    // Suppressed display values — clamp near-zero noise to exactly 0 at standstill
    private var displaySpeedKMH: Double {
        ui.suppressIdleAnomalies && abs(vm.speedKMH) < 1.0 ? 0.0 : vm.speedKMH
    }
    private var displayDuty: Double {
        ui.suppressIdleAnomalies && abs(Double(t.dutyCycle)) < 0.01 ? 0.0 : Double(t.dutyCycle)
    }
    private var displayRPM: Int32 {
        ui.suppressIdleAnomalies && abs(vm.speedKMH) < 1.0 ? 0 : t.rpm
    }

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
            .background(
                (ui.lightMode ? Color(.systemGroupedBackground) : Color.black)
                    .ignoresSafeArea()
            )
            .navigationTitle("VESC Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(ui.lightMode ? nil : .dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    connectionButton
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showLog = true } label: {
                            Label("Log", systemImage: "list.bullet.rectangle")
                        }
                        if ui.showMotorDetection {
                            Button { showMotorWizard = true } label: {
                                Label("Motor Wizard", systemImage: "wand.and.stars")
                            }
                        }
                        Button { showMotorProfile = true } label: {
                            Label("Profile", systemImage: "slider.horizontal.3")
                        }
                        Button { showMotorConfig = true } label: {
                            Label("Motor Config", systemImage: "bolt.circle")
                        }
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Button { showUISettings = true } label: {
                            Label("UI Settings", systemImage: "paintbrush")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
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
            .sheet(isPresented: $showMotorWizard) {
                MotorWizardView(vm: vm)
            }
            .sheet(isPresented: $showMotorProfile) {
                MotorProfileListView(vm: vm)
            }
            .sheet(isPresented: $showUISettings) {
                UISettingsView(vm: vm)
            }
        }
        .preferredColorScheme(ui.lightMode ? .light : .dark)
    }

    // MARK: - Speed Gauge

    private var speedGauge: some View {
        ZStack {
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(ui.lightMode ? Color(.systemGray4) : .white.opacity(0.06),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: 220, height: 220)

            let fraction = min(1.0, abs(displaySpeedKMH) / 60.0)
            let fillColors: [Color] = ui.lightMode ? [Color(.systemGray2), Color(.systemGray3)] : [.cyan, .blue]
            Circle()
                .trim(from: 0.15, to: 0.15 + 0.7 * fraction)
                .stroke(
                    LinearGradient(colors: fillColors, startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
                .frame(width: 220, height: 220)
                .animation(ui.reduceStatisticsAnimations ? nil : .easeInOut(duration: 0.15), value: fraction)

            VStack(spacing: 2) {
                Text(String(format: "%.1f", displaySpeedKMH))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(ui.reduceStatisticsAnimations ? .identity : .numericText(countsDown: displaySpeedKMH < 0))
                    .animation(ui.reduceStatisticsAnimations ? nil : .easeInOut(duration: 0.15), value: displaySpeedKMH)

                Text("km/h")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(displayRPM) ERPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(ui.reduceStatisticsAnimations ? .identity : .numericText())
                    .animation(ui.reduceStatisticsAnimations ? nil : .easeInOut(duration: 0.15), value: displayRPM)

                if ui.showGPSSpeed {
                    gpsSpeedBadge
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - GPS Speed Badge

    @ViewBuilder
    private var gpsSpeedBadge: some View {
        if let gps = vm.gpsSpeedKMH {
            HStack(spacing: 3) {
                Image(systemName: "location.fill")
                    .font(.system(size: 9))
                Text(String(format: "%.1f", gps))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .contentTransition(ui.reduceStatisticsAnimations ? .identity : .numericText())
                    .animation(ui.reduceStatisticsAnimations ? nil : .easeInOut(duration: 0.2), value: gps)
                Text("GPS")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.green)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "location.slash")
                    .font(.system(size: 9))
                Text("GPS…")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
        }
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
                currentValue: Double(t.inputVoltage),
                animated: !ui.reduceStatisticsAnimations,
                lightMode: ui.lightMode
            )
            MetricCard(
                label: "Battery A",
                value: String(format: "%.1f", t.batteryCurrent),
                unit: "A",
                accentColor: .yellow,
                icon: "battery.100",
                animated: !ui.reduceStatisticsAnimations,
                lightMode: ui.lightMode
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
                currentValue: Double(t.mosfetTemperature),
                animated: !ui.reduceStatisticsAnimations,
                lightMode: ui.lightMode
            )
            MetricCard(
                label: "Motor Temp",
                value: String(format: "%.1f", t.motorTemperature),
                unit: "°C",
                accentColor: .orange,
                icon: "thermometer.high",
                warningThreshold: 100,
                currentValue: Double(t.motorTemperature),
                animated: !ui.reduceStatisticsAnimations,
                lightMode: ui.lightMode
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
                icon: "bolt.ring.closed",
                animated: !ui.reduceStatisticsAnimations,
                lightMode: ui.lightMode
            )
            MetricCard(
                label: "Power",
                value: String(format: "%.0f", t.inputVoltage * t.batteryCurrent),
                unit: "W",
                accentColor: .purple,
                icon: "flame.fill",
                animated: !ui.reduceStatisticsAnimations,
                lightMode: ui.lightMode
            )
        }
    }

    // MARK: - Duty Cycle Bar

    private var dutyCycleBar: some View {
        BarMetricCard(
            label: "Duty Cycle",
            value: displayDuty,
            displayText: String(format: "%.1f%%", displayDuty * 100),
            accentColor: .cyan,
            icon: "gauge.with.needle",
            animated: !ui.reduceStatisticsAnimations,
            lightMode: ui.lightMode
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
                icon: "chart.line.downtrend.xyaxis",
                animated: !ui.reduceStatisticsAnimations,
                lightMode: ui.lightMode
            )
            MetricCard(
                label: "Ah Used",
                value: String(format: "%.3f", t.ampHours),
                unit: "Ah",
                accentColor: .teal,
                icon: "minus.forwardslash.plus",
                animated: !ui.reduceStatisticsAnimations,
                lightMode: ui.lightMode
            )
        }
    }

    // MARK: - Peak Stats

    private var peakStatsRow: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Session Peak", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { vm.resetPeakStats() } label: {
                    Text("Reset").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)

            HStack(spacing: 0) {
                peakCell("Top Speed",    String(format: "%.1f", vm.peakSpeedKMH),      "km/h")
                Rectangle().fill(ui.lightMode ? Color(.systemGray4) : .white.opacity(0.12)).frame(width: 1, height: 28)
                peakCell("Peak Power",   String(format: "%.0f", vm.peakPowerW),         "W")
                Rectangle().fill(ui.lightMode ? Color(.systemGray4) : .white.opacity(0.12)).frame(width: 1, height: 28)
                peakCell("Peak Motor A", String(format: "%.1f", vm.peakMotorCurrentA),  "A")
                if ui.showGPSSpeed {
                    Rectangle().fill(ui.lightMode ? Color(.systemGray4) : .white.opacity(0.12)).frame(width: 1, height: 28)
                    peakCell("GPS Top Speed", String(format: "%.1f", vm.peakGPSSpeedKMH), "km/h")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(ui.lightMode ? Color(.systemGray6) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func peakCell(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
    vm.peakSpeedKMH = 48.2
    vm.peakPowerW = 1840
    vm.peakMotorCurrentA = 42.1
    return DashboardView(vm: vm)
}

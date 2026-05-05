import SwiftUI

/// A single rounded-rectangle tile showing a label, animated value, and unit.
struct MetricCard: View {
    let label: String
    let value: String
    let unit: String
    var accentColor: Color = .cyan
    var icon: String? = nil
    var warningThreshold: Double? = nil
    var currentValue: Double? = nil

    private var isWarning: Bool {
        guard let t = warningThreshold, let v = currentValue else { return false }
        return v >= t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(isWarning ? .red : accentColor)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(isWarning ? .red : .primary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: value)

                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isWarning ? Color.red.opacity(0.6) : accentColor.opacity(0.15), lineWidth: 1)
        )
    }
}

/// A thin horizontal progress-bar card — useful for duty cycle and battery.
struct BarMetricCard: View {
    let label: String
    let value: Double   // 0…1 fraction
    let displayText: String
    var accentColor: Color = .cyan
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(accentColor)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: displayText)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 8)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, abs(value)))), height: 8)
                        .animation(.easeInOut(duration: 0.15), value: value)
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
        )
    }

    private var barColor: Color {
        switch value {
        case 0.8...: return .red
        case 0.6...: return .orange
        default: return accentColor
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        HStack {
            MetricCard(label: "Motor Temp", value: "72.4", unit: "°C",
                       accentColor: .orange, icon: "thermometer",
                       warningThreshold: 80, currentValue: 72.4)
            MetricCard(label: "Voltage", value: "41.2", unit: "V",
                       accentColor: .green, icon: "bolt.fill")
        }
        BarMetricCard(label: "Duty Cycle", value: 0.65, displayText: "65%",
                      accentColor: .cyan, icon: "gauge")
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}

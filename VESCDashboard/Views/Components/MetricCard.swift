import SwiftUI

extension Color {
    static let dynetraOrange = Color(red: 206/255, green: 95/255, blue: 14/255)
}

struct MetricCard: View {
    let label: String
    let value: String
    let unit: String
    var accentColor: Color = .cyan
    var icon: String? = nil
    var warningThreshold: Double? = nil
    var currentValue: Double? = nil
    var animated: Bool = true
    var lightMode: Bool = false

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
                    .contentTransition(animated ? .numericText() : .identity)
                    .animation(animated ? .easeInOut(duration: 0.2) : nil, value: value)

                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(lightMode ? AnyShapeStyle(Color(.systemGray6)) : AnyShapeStyle(.ultraThinMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isWarning ? Color.red.opacity(0.6) : Color.dynetraOrange.opacity(lightMode ? 0.55 : 0.4), lineWidth: 1)
        )
    }
}

struct BarMetricCard: View {
    let label: String
    let value: Double
    let displayText: String
    var accentColor: Color = .cyan
    var icon: String? = nil
    var animated: Bool = true
    var animateBar: Bool = true
    var lightMode: Bool = false

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
                    .contentTransition(animated ? .numericText() : .identity)
                    .animation(animated ? .easeInOut(duration: 0.2) : nil, value: displayText)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 8)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, abs(value)))), height: 8)
                        .animation(animateBar ? .easeInOut(duration: 0.15) : nil, value: value)
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(lightMode ? AnyShapeStyle(Color(.systemGray6)) : AnyShapeStyle(.ultraThinMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.dynetraOrange.opacity(lightMode ? 0.55 : 0.4), lineWidth: 1)
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

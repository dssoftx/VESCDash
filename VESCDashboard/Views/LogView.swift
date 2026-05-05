import SwiftUI

struct LogView: View {
    let logs: [String]
    @State private var filterText = ""
    @State private var autoscroll = true
    @Environment(\.dismiss) private var dismiss

    private var filteredLogs: [String] {
        filterText.isEmpty ? logs : logs.filter { $0.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter…", text: $filterText)
                        .autocorrectionDisabled()
                    if !filterText.isEmpty {
                        Button { filterText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial)

                Divider()

                if filteredLogs.isEmpty {
                    Spacer()
                    Text(logs.isEmpty ? "No log entries yet." : "No matches for \"\(filterText)\"")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(filteredLogs.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(color(for: line))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .onChange(of: logs.count) { _ in
                            if autoscroll, let last = filteredLogs.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("BLE Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { autoscroll.toggle() } label: {
                        Image(systemName: autoscroll ? "arrow.down.to.line" : "pause.circle")
                            .foregroundStyle(autoscroll ? .cyan : .secondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func color(for line: String) -> Color {
        if line.contains("[FAULT]") || line.contains("error") || line.contains("Error") {
            return .red
        } else if line.contains("[TIMEOUT]") || line.contains("timeout") {
            return .orange
        } else if line.contains("Packet OK") || line.contains("Connected") {
            return .green
        } else if line.contains("PARSE ERROR") {
            return .red
        } else {
            return .secondary
        }
    }
}

#Preview {
    LogView(logs: [
        "[12:00:01] Bluetooth ready",
        "[12:00:02] Scanning for VESC devices…",
        "[12:00:03] Found VESC 4.12 RSSI=-62",
        "[12:00:04] Connected — discovering services…",
        "[12:00:04] RX char found — subscribing",
        "[12:00:05] Packet OK cmd=4 len=54",
        "[12:00:05] [FAULT] Over Temp Motor",
        "[12:00:06] [TIMEOUT] No response for 3s",
    ])
}

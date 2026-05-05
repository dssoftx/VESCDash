import Foundation
import Combine
import SwiftUI

// MARK: - Supporting enums

enum MotorLimitsSendState: Equatable {
    case idle
    case sent(String)
    case failed(String)
}

enum MotorLimitsReadState: Equatable {
    case idle
    case reading
    case loaded
    case failed(String)
}

// MARK: - Drivetrain Settings

struct DrivetrainSettings: Codable {
    /// Motor pole pairs (poles ÷ 2). 30-pole hub motor = 15 pairs.
    var motorPolePairs: Double = 15
    /// Gear reduction ratio. 0 = direct drive / hub motor (treated as 1:1 internally).
    var gearRatio: Double = 0
    /// Wheel diameter in millimetres.
    var wheelDiameterMM: Double = 241.0

    var wheelCircumferenceM: Double { (.pi * wheelDiameterMM) / 1000.0 }

    /// Converts VESC ERPM to km/h. Gear ratio 0 is treated as direct drive (1:1).
    func speedKMH(erpm: Int32) -> Double {
        let ratio = gearRatio == 0 ? 1.0 : gearRatio
        let mechanicalRPM = Double(erpm) / motorPolePairs
        let wheelRPM = mechanicalRPM / ratio
        return (wheelRPM / 60.0) * wheelCircumferenceM * 3.6
    }
}

// MARK: - ViewModel

@MainActor
final class TelemetryViewModel: ObservableObject {

    // MARK: Live telemetry
    @Published var telemetry: TelemetryData = .empty
    @Published var speedKMH: Double = 0

    // MARK: Peak stats (reset on disconnect or CAN-node switch)
    @Published var peakSpeedKMH: Double = 0
    @Published var peakPowerW: Double = 0
    @Published var peakMotorCurrentA: Float = 0

    // MARK: Settings
    @Published var settings = DrivetrainSettings()
    @Published var motorLimits = MotorLimitsConfig()

    // MARK: Motor config send/read states
    @Published var motorLimitsSendState: MotorLimitsSendState = .idle
    @Published var motorLimitsReadState: MotorLimitsReadState = .idle

    // MARK: CAN bus
    @Published var canNodes: [CANNode] = []
    @Published var selectedCANID: Int? = nil   // nil = local (master) VESC
    @Published var isScanningCAN = false
    @Published var persistedCANIDs: [Int] = []
    @Published var localFWVersion: String? = nil   // firmware version of the directly-connected VESC
    private var pingCANNodesCountBefore = 0
    private var pendingFWVersionCANID: Int? = nil    // the node currently being queried
    private var fwVersionQueue: [Int] = []           // nodes waiting for a FW_VERSION request
    private var pendingLocalFWVersion = false

    // MARK: Connection
    @Published var logs: [String] = []
    @Published var isConnected = false
    @Published var connectionStateName = ""

    let bleManager: BLEManager

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: AnyCancellable?
    private var lastPacketTime: Date?
    private let timeoutInterval: TimeInterval = 3.0
    private let maxLogLines = 300

    init(bleManager: BLEManager = BLEManager()) {
        self.bleManager = bleManager
        loadPersistedSettings()
        setupBindings()
    }

    // MARK: - Public — Queries

    /// Label shown in the connection button. Includes CAN node suffix when one is selected.
    var activeVESCLabel: String {
        guard isConnected else { return "" }
        if let id = selectedCANID { return "\(connectionStateName) / CAN #\(id)" }
        return connectionStateName
    }

    // MARK: - Public — Commands

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.requestTelemetry() }
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Scans for CAN nodes via COMM_PING_CAN. The firmware internally pings all 254 CAN IDs
    /// and returns a list of respondents. Waits 8 s (254 nodes × ~20 ms ≈ 5 s worst case).
    func pingCAN() {
        guard isConnected else { return }
        isScanningCAN = true
        pingCANNodesCountBefore = canNodes.count
        bleManager.send(VESCProtocolParser.buildPingCANCommand())
        appendLog("[CAN] Scanning CAN bus…")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.isScanningCAN = false
            let found = self.canNodes.map { String($0.id) }.joined(separator: ", ")
            self.appendLog("[CAN] Scan done — \(found.isEmpty ? "no nodes found (add manually)" : "nodes: \(found)")")
        }
    }

    /// Adds a CAN node permanently (survives disconnect/reconnect) and requests its firmware version.
    func addCANNode(id: Int) {
        if !persistedCANIDs.contains(id) {
            persistedCANIDs.append(id)
            persistedCANIDs.sort()
            saveCANIDs()
        }
        mergeNodeID(id)
        requestFWVersion(canID: id)
    }

    /// Removes a CAN node from both the live list and persistent storage.
    func removeCANNode(id: Int) {
        canNodes.removeAll { $0.id == id }
        persistedCANIDs.removeAll { $0 == id }
        saveCANIDs()
        if selectedCANID == id { selectVESC(canID: nil) }
    }

    /// Selects a target VESC. nil = local (master), otherwise the CAN node id.
    /// Resets peak stats since we're now monitoring a different controller.
    func selectVESC(canID: Int?) {
        guard canID != selectedCANID else { return }
        selectedCANID = canID
        resetPeakStats()
        appendLog("[CAN] Switched to \(canID.map { "CAN #\($0)" } ?? "local VESC")")
        if let id = canID { requestFWVersion(canID: id) }
    }

    /// Enqueues a COMM_FW_VERSION request for a CAN node; dispatches immediately if idle.
    private func requestFWVersion(canID: Int) {
        guard isConnected else { return }
        guard pendingFWVersionCANID != canID, !fwVersionQueue.contains(canID) else { return }
        fwVersionQueue.append(canID)
        if pendingFWVersionCANID == nil { drainFWVersionQueue() }
    }

    /// Sends the next queued FW_VERSION request. Call after each response (or timeout).
    private func drainFWVersionQueue() {
        guard let canID = fwVersionQueue.first, isConnected else {
            pendingFWVersionCANID = nil
            return
        }
        fwVersionQueue.removeFirst()
        pendingFWVersionCANID = canID
        bleManager.send(VESCProtocolParser.buildForwardCAN(toID: UInt8(canID), commandPayload: [0]))
        // 2 s timeout — move on if VESC doesn't reply
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.pendingFWVersionCANID == canID else { return }
            self.appendLog("[CAN] FW_VERSION timeout for CAN #\(canID)")
            self.pendingFWVersionCANID = nil
            self.drainFWVersionQueue()
        }
    }

    /// Reads the current motor config from the active VESC and updates `motorLimits`.
    func fetchMotorConfig() {
        guard isConnected else {
            motorLimitsReadState = .failed("Not connected")
            return
        }
        motorLimitsReadState = .reading
        sendCommand([VESCCommand.getMCConf.rawValue])
        appendLog("[MCCONF] Requesting motor config…")

        // Timeout: if no response in 3s, mark failed
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .reading = self.motorLimitsReadState {
                self.motorLimitsReadState = .failed("No response (timeout)")
                self.appendLog("[MCCONF] Timeout reading motor config")
            }
        }
    }

    /// Reads motor config from a specific CAN node into motorLimits (ignores selectedCANID).
    func fetchMotorConfigFrom(canID: Int) {
        guard isConnected else { motorLimitsReadState = .failed("Not connected"); return }
        motorLimitsReadState = .reading
        bleManager.send(VESCProtocolParser.buildForwardCAN(toID: UInt8(canID),
                                                           commandPayload: [VESCCommand.getMCConf.rawValue]))
        appendLog("[MCCONF] Requesting motor config from CAN #\(canID)…")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .reading = self.motorLimitsReadState {
                self.motorLimitsReadState = .failed("No response (timeout)")
                self.appendLog("[MCCONF] Timeout reading from CAN #\(canID)")
            }
        }
    }

    /// Sends current motorLimits to a specific CAN node (ignores selectedCANID).
    func sendMotorLimitsTo(canID: Int, storeToFlash: Bool = false) {
        guard isConnected else { motorLimitsSendState = .failed("Not connected"); return }
        var payload: [UInt8] = [VESCCommand.setMCConfTemp.rawValue]
        payload.append(storeToFlash ? 1 : 0)
        payload.append(0)   // forward_can = false
        payload.append(1)   // ack
        payload.append(0)   // divide_by_controllers = false
        appendFloat32BE(&payload, motorLimits.phaseCurrentMax)
        appendFloat32BE(&payload, -abs(motorLimits.phaseCurrentMax))
        appendFloat32BE(&payload, motorLimits.batteryCurrentMax)
        appendFloat32BE(&payload, min(motorLimits.batteryCurrentRegen, 0))
        appendFloat32BE(&payload, motorLimits.absCurrentMax)
        bleManager.send(VESCProtocolParser.buildForwardCAN(toID: UInt8(canID), commandPayload: payload))
        saveMotorLimits()
        motorLimitsSendState = .sent("Sent to CAN #\(canID)\(storeToFlash ? " · saved" : "")")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .sent = self.motorLimitsSendState { self.motorLimitsSendState = .idle }
        }
    }

    func saveSettings() {
        if let d = try? JSONEncoder().encode(settings)     { UserDefaults.standard.set(d, forKey: "drivetrainSettings") }
    }

    func saveMotorLimits() {
        if let d = try? JSONEncoder().encode(motorLimits)  { UserDefaults.standard.set(d, forKey: "motorLimitsConfig") }
    }

    func resetPeakStats() {
        peakSpeedKMH = 0
        peakPowerW = 0
        peakMotorCurrentA = 0
    }

    /// Sends current motor limits to the active VESC via COMM_SET_MCCONF_TEMP.
    func sendMotorLimits(storeToFlash: Bool) {
        guard isConnected else { motorLimitsSendState = .failed("Not connected"); return }

        var payload: [UInt8] = [VESCCommand.setMCConfTemp.rawValue]
        payload.append(storeToFlash ? 1 : 0)  // store
        payload.append(0)                      // forward_can = false (we handle forwarding below)
        payload.append(1)                      // ack
        payload.append(0)                      // divide_by_controllers = false
        appendFloat32BE(&payload, motorLimits.phaseCurrentMax)
        appendFloat32BE(&payload, -abs(motorLimits.phaseCurrentMax))
        appendFloat32BE(&payload, motorLimits.batteryCurrentMax)
        appendFloat32BE(&payload, min(motorLimits.batteryCurrentRegen, 0))
        appendFloat32BE(&payload, motorLimits.absCurrentMax)

        sendCommand(payload)
        saveMotorLimits()

        motorLimitsSendState = .sent(storeToFlash ? "Sent & saved to flash" : "Sent (RAM only)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .sent = self.motorLimitsSendState { self.motorLimitsSendState = .idle }
        }
    }

    // MARK: - Private — Outgoing

    /// Sends a raw command payload, wrapping in COMM_FORWARD_CAN if a CAN node is selected.
    private func sendCommand(_ commandPayload: [UInt8]) {
        let packet: [UInt8]
        if let canID = selectedCANID {
            packet = VESCProtocolParser.buildForwardCAN(toID: UInt8(canID), commandPayload: commandPayload)
        } else {
            packet = VESCProtocolParser.buildPacket(payload: commandPayload)
        }
        bleManager.send(packet)
    }

    private func requestTelemetry() {
        guard isConnected else { return }

        if let last = lastPacketTime, Date().timeIntervalSince(last) > timeoutInterval {
            appendLog("[TIMEOUT] No response for \(Int(timeoutInterval))s")
            lastPacketTime = Date()
        }

        sendCommand([VESCCommand.getValues.rawValue])
    }

    // MARK: - Private — Incoming

    private func handlePacket(_ payload: [UInt8]) {
        guard let cmd = payload.first else { return }
        lastPacketTime = Date()

        switch cmd {
        case VESCCommand.getValues.rawValue:
            handleTelemetry(payload)

        case VESCCommand.getMCConf.rawValue:
            handleMCConf(payload)

        case VESCCommand.pingCAN.rawValue:
            handleCANPing(payload)

        case VESCCommand.setMCConfTemp.rawValue:
            appendLog("[MCCONF] Limits accepted by VESC")

        case 0:  // COMM_FW_VERSION
            if pendingLocalFWVersion {
                applyLocalFWVersion(payload)
                pendingLocalFWVersion = false
            } else if let nodeID = pendingFWVersionCANID {
                applyFWVersion(payload, toNodeID: nodeID)
                pendingFWVersionCANID = nil
                drainFWVersionQueue()
            }

        case VESCCommand.forwardCAN.rawValue:  // 34 — master may wrap CAN-node responses
            if payload.count >= 3 {
                let srcID  = Int(payload[1])
                let innerCmd = payload[2]
                if innerCmd == 0, let nodeID = pendingFWVersionCANID, nodeID == srcID {
                    applyFWVersion(Array(payload[2...]), toNodeID: nodeID)
                    pendingFWVersionCANID = nil
                    drainFWVersionQueue()
                }
            }

        default:
            break  // ignore unknown commands silently
        }
    }

    private func applyFWVersion(_ payload: [UInt8], toNodeID id: Int) {
        guard payload.count >= 3, payload[0] == 0 else { return }
        let major = payload[1], minor = payload[2]
        var hw = ""
        var i = 3
        while i < payload.count && payload[i] != 0 {
            hw.append(Character(UnicodeScalar(payload[i])))
            i += 1
        }
        let version = hw.isEmpty ? "\(major).\(String(format: "%02d", minor))"
                                 : "\(major).\(String(format: "%02d", minor)) · \(hw)"
        mergeNodeID(id)
        if let idx = canNodes.firstIndex(where: { $0.id == id }) {
            canNodes[idx].hwVersion = version
        }
        appendLog("[CAN] CAN #\(id) firmware: \(version)")
    }

    private func applyLocalFWVersion(_ payload: [UInt8]) {
        guard payload.count >= 3, payload[0] == 0 else { return }
        let major = payload[1], minor = payload[2]
        var hw = ""
        var i = 3
        while i < payload.count && payload[i] != 0 {
            hw.append(Character(UnicodeScalar(payload[i])))
            i += 1
        }
        localFWVersion = hw.isEmpty ? "\(major).\(String(format: "%02d", minor))"
                                    : "\(major).\(String(format: "%02d", minor)) · \(hw)"
        appendLog("[FW] Local VESC firmware: \(localFWVersion!)")
    }

    private func requestLocalFWVersion() {
        guard isConnected else { return }
        pendingLocalFWVersion = true
        bleManager.send(VESCProtocolParser.buildPacket(payload: [0]))  // COMM_FW_VERSION directly
    }

    private func handleTelemetry(_ payload: [UInt8]) {
        do {
            let data = try VESCProtocolParser.parseTelemetry(payload: payload)

            telemetry = data
            speedKMH = settings.speedKMH(erpm: data.rpm)

            // Update peak stats
            peakSpeedKMH = max(peakSpeedKMH, abs(speedKMH))
            let power = Double(data.inputVoltage) * Double(abs(data.batteryCurrent))
            peakPowerW = max(peakPowerW, power)
            peakMotorCurrentA = max(peakMotorCurrentA, abs(data.motorCurrent))

            if data.hasFault { appendLog("[FAULT] \(data.faultDescription)") }
        } catch {
            appendLog("[PARSE ERROR] \(error.localizedDescription)")
        }
    }

    private func handleMCConf(_ payload: [UInt8]) {
        do {
            let limits = try VESCProtocolParser.parseMCConfLimits(payload: payload)
            motorLimits = limits
            saveMotorLimits()
            motorLimitsReadState = .loaded
            appendLog("[MCCONF] Loaded: phase=\(Int(limits.phaseCurrentMax))A batt=\(Int(limits.batteryCurrentMax))A regen=\(Int(limits.batteryCurrentRegen))A abs=\(Int(limits.absCurrentMax))A")
        } catch {
            motorLimitsReadState = .failed(error.localizedDescription)
            appendLog("[MCCONF] Parse error: \(error.localizedDescription)")
        }
    }

    private func handleCANPing(_ payload: [UInt8]) {
        let hex = payload.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        appendLog("[CAN] PING_CAN reply \(payload.count)B: \(hex)\(payload.count > 16 ? "…" : "")")
        let ids = VESCProtocolParser.parseCANPingResponse(payload: payload)
        for id in ids { mergeNodeID(id) }
        appendLog("[CAN] PING_CAN found \(ids.count) node(s): \(ids.map(String.init).joined(separator: ", "))")
        // Fetch FW version for any node that doesn't have one yet
        for id in ids where canNodes.first(where: { $0.id == id })?.hwVersion == nil {
            requestFWVersion(canID: id)
        }
    }

    private func mergeNodeID(_ id: Int) {
        guard !canNodes.contains(where: { $0.id == id }) else { return }
        canNodes.append(CANNode(id: id))
        canNodes.sort { $0.id < $1.id }
    }

    // MARK: - Persistence

    private func loadPersistedSettings() {
        if let d = UserDefaults.standard.data(forKey: "drivetrainSettings"),
           let s = try? JSONDecoder().decode(DrivetrainSettings.self, from: d) { settings = s }
        if let d = UserDefaults.standard.data(forKey: "motorLimitsConfig"),
           let m = try? JSONDecoder().decode(MotorLimitsConfig.self, from: d) { motorLimits = m }
        if let d = UserDefaults.standard.data(forKey: "persistedCANIDs"),
           let ids = try? JSONDecoder().decode([Int].self, from: d) {
            persistedCANIDs = ids
            canNodes = ids.map { CANNode(id: $0) }
        }
    }

    private func saveCANIDs() {
        if let d = try? JSONEncoder().encode(persistedCANIDs) {
            UserDefaults.standard.set(d, forKey: "persistedCANIDs")
        }
    }

    // MARK: - Bindings

    private func setupBindings() {
        bleManager.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .connected(let name):
                    self.isConnected = true
                    self.connectionStateName = name
                    self.startPolling()
                    self.requestLocalFWVersion()
                    // Enqueue FW requests for persisted CAN nodes; small delay lets the local
                    // FW_VERSION response arrive first (local check is prioritised in handlePacket).
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        for id in self.persistedCANIDs {
                            self.requestFWVersion(canID: id)
                        }
                    }
                case .idle, .failed:
                    self.isConnected = false
                    self.connectionStateName = ""
                    self.stopPolling()
                    self.telemetry = .empty
                    self.speedKMH = 0
                    self.localFWVersion = nil
                    self.fwVersionQueue.removeAll()
                    self.pendingFWVersionCANID = nil
                    self.pendingLocalFWVersion = false
                    // Restore persisted nodes; clear any scan-only discoveries
                    self.canNodes = self.persistedCANIDs.map { CANNode(id: $0) }
                    self.selectedCANID = nil
                    self.isScanningCAN = false
                    self.motorLimitsReadState = .idle
                    self.resetPeakStats()
                case .scanning:
                    self.connectionStateName = "Scanning…"
                case .connecting:
                    self.connectionStateName = "Connecting…"
                }
            }
            .store(in: &cancellables)

        bleManager.packetReceived
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in self?.handlePacket(payload) }
            .store(in: &cancellables)

        bleManager.logLine
            .receive(on: RunLoop.main)
            .sink { [weak self] line in self?.appendLog(line) }
            .store(in: &cancellables)
    }

    // MARK: - Log

    private func appendLog(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(ts)] \(line)")
        if logs.count > maxLogLines { logs.removeFirst(logs.count - maxLogLines) }
    }

    // MARK: - Float helper (IEEE-754 big-endian)

    private func appendFloat32BE(_ buf: inout [UInt8], _ value: Float) {
        let bits = value.bitPattern
        buf.append(UInt8((bits >> 24) & 0xFF))
        buf.append(UInt8((bits >> 16) & 0xFF))
        buf.append(UInt8((bits >> 8)  & 0xFF))
        buf.append(UInt8( bits        & 0xFF))
    }
}

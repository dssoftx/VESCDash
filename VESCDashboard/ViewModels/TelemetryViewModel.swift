import Foundation
import Combine
import SwiftUI

// MARK: - Supporting enums

// MARK: - Motor Detection

enum WizardDetectionState: Equatable {
    case idle
    case measuringRL
    case rlResult(r: Float, l: Float, ldLqDiff: Float)   // Ω, µH, µH
    case measuringLinkage(r: Float, l: Float, ldLqDiff: Float)
    case complete(r: Float, l: Float, ldLqDiff: Float, lambda: Float) // λ in Wb
    case failed(String)
}

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

struct UISettings: Codable {
    var suppressIdleAnomalies: Bool = false
    var reduceStatisticsAnimations: Bool = false
    var lightMode: Bool = false
    var showGPSSpeed: Bool = false
    var showMotorDetection: Bool = false
    var runVerificationMode: Bool = false
    var showBatteryPercentage: Bool = false
    var batteryEmptyVoltage: Double = 33.0
    var batteryFullVoltage: Double = 42.0
}

final class TelemetryViewModel: ObservableObject {

    // MARK: Live telemetry
    @Published var telemetry: TelemetryData = .empty
    @Published var speedKMH: Double = 0

    // MARK: Peak stats (reset on disconnect or CAN-node switch)
    @Published var peakSpeedKMH: Double = 0
    @Published var peakGPSSpeedKMH: Double = 0
    @Published var peakPowerW: Double = 0
    @Published var peakMotorCurrentA: Float = 0

    // MARK: Settings
    @Published var settings = DrivetrainSettings()
    @Published var uiSettings = UISettings()
    @Published var batteryConfig = BatteryConfig()
    @Published var motorLimits = MotorLimitsConfig()
    @Published var motorProfile = MotorProfile()
    @Published var savedProfiles: [MotorProfile] = []

    // MARK: Motor config send/read states
    @Published var motorLimitsSendState: MotorLimitsSendState = .idle
    @Published var motorLimitsReadState: MotorLimitsReadState = .idle

    // MARK: Motor detection (wizard)
    @Published var detectionState: WizardDetectionState = .idle

    // MARK: CAN bus
    @Published var canNodes: [CANNode] = []
    @Published var selectedCANID: Int? = nil   // nil = local (master) VESC
    @Published var isScanningCAN = false
    @Published var persistedCANIDs: [Int] = []
    @Published var localFWVersion: String? = nil    // firmware version of the directly-connected VESC (display string)
    @Published var localFWVersionInt: Int? = nil   // major×100 + minor (e.g. 6.05 → 605); nil until received
    private var pingCANNodesCountBefore = 0
    private var pendingFWVersionCANID: Int? = nil
    private var fwVersionQueue: [Int] = []
    private var pendingLocalFWVersion = false

    // MARK: Motor config cache (raw MCCONF payloads for read-modify-write)
    private enum MCConfSource { case local; case can(Int) }
    private var pendingMCConfSource: MCConfSource = .local
    private var rawMCConfLocal: [UInt8]? = nil
    private var rawMCConfByCANID: [Int: [UInt8]] = [:]

    // Background MCCONF auto-fetch queue (nil = local VESC, Int = CAN ID)
    private var bgMCConfQueue: [Int?] = []
    private var isBgFetchingMCConf = false

    var hasMCConfCache: Bool {
        if let id = selectedCANID { return rawMCConfByCANID[id] != nil }
        return rawMCConfLocal != nil
    }

    /// True when the connected firmware version is known and not in `allowedFirmwareVersions`.
    /// COMM_SET_MCCONF and FOC detection writes are blocked. COMM_SET_MCCONF_TEMP (profiles) always allowed.
    var fwMCConfBlocked: Bool {
        guard let v = localFWVersionInt else { return false }
        return !VESCProtocolParser.allowedFirmwareVersions.contains(v)
    }

    // MARK: Compatibility
    @Published var mcconfCompatWarning: String? = nil

    // MARK: GPS
    let locationManager = LocationManager()
    @Published var gpsSpeedKMH: Double? = nil

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
        if isConnected { enqueueBgMCConfFetch(id) }
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

    // MARK: - Background MCCONF Auto-Fetch

    /// Enqueues a silent MCCONF fetch for `canID` (nil = local). Deduplicates and starts the
    /// queue drain immediately if nothing is already in flight.
    func enqueueBgMCConfFetch(_ canID: Int?) {
        guard !bgMCConfQueue.contains(where: { $0 == canID }) else { return }
        bgMCConfQueue.append(canID)
        if !isBgFetchingMCConf { drainBgMCConfQueue() }
    }

    private func drainBgMCConfQueue() {
        guard !bgMCConfQueue.isEmpty, isConnected,
              motorLimitsReadState != .reading else {
            isBgFetchingMCConf = false
            return
        }
        let source = bgMCConfQueue.removeFirst()
        isBgFetchingMCConf = true
        pendingMCConfSource = source.map { .can($0) } ?? .local
        let label = source.map { "CAN #\($0)" } ?? "local"

        if let id = source {
            bleManager.send(VESCProtocolParser.buildForwardCAN(
                toID: UInt8(id), commandPayload: [VESCCommand.getMCConf.rawValue]))
        } else {
            bleManager.send(VESCProtocolParser.buildPacket(payload: [VESCCommand.getMCConf.rawValue]))
        }
        appendLog("[AUTO] Fetching MCCONF from \(label)…")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self.isBgFetchingMCConf else { return }
            self.appendLog("[AUTO] MCCONF timeout for \(label)")
            self.isBgFetchingMCConf = false
            self.drainBgMCConfQueue()
        }
    }

    /// Reads the current motor config from the active VESC and updates `motorLimits`.
    func fetchMotorConfig() {
        guard isConnected else {
            motorLimitsReadState = .failed("Not connected")
            return
        }
        isBgFetchingMCConf = false   // user-initiated fetch takes priority
        motorLimitsReadState = .reading
        pendingMCConfSource = selectedCANID.map { .can($0) } ?? .local
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
        pendingMCConfSource = .can(canID)
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

    // MARK: - Motor Detection (Wizard)

    /// Sends COMM_DETECT_MOTOR_R_L. Motor makes noise but does not rotate.
    func measureRL() {
        guard isConnected else { detectionState = .failed("Not connected"); return }
        detectionState = .measuringRL
        sendCommand([VESCCommand.measureRL.rawValue])
        appendLog("[DETECT] Measuring R & L…")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if case .measuringRL = self.detectionState {
                self.detectionState = .failed("R/L measurement timed out")
                self.appendLog("[DETECT] R/L timeout")
            }
        }
    }

    /// Sends COMM_DETECT_MOTOR_FLUX_LINKAGE_OPENLOOP. Motor will spin — user must be warned first.
    /// - Parameters:
    ///   - current:    Detection current (A); l_current_max/3 is a safe default.
    ///   - erpmPerSec: Open-loop ramp rate in ERPM/s (default 700).
    ///   - lowDuty:    Starting duty cycle (default 0.06).
    func measureFluxLinkageOpenloop(current: Float, erpmPerSec: Float = 700, lowDuty: Float = 0.06) {
        guard isConnected else { detectionState = .failed("Not connected"); return }
        guard case .rlResult(let r, let l, let ldLq) = detectionState else {
            detectionState = .failed("Run R/L measurement first")
            return
        }
        detectionState = .measuringLinkage(r: r, l: l, ldLqDiff: ldLq)
        let inductance_H = l / 1_000_000.0
        var payload: [UInt8] = [VESCCommand.measureFluxLinkageOpenloop.rawValue]
        func app32(_ v: Int32) {
            let u = UInt32(bitPattern: v)
            payload += [UInt8((u>>24)&0xFF), UInt8((u>>16)&0xFF), UInt8((u>>8)&0xFF), UInt8(u&0xFF)]
        }
        app32(Int32(current    * 1_000))
        app32(Int32(erpmPerSec * 1_000))
        app32(Int32(lowDuty    * 1_000))
        app32(Int32(r          * 1_000_000))
        app32(Int32(inductance_H * 100_000_000))
        sendCommand(payload)
        appendLog("[DETECT] Measuring flux linkage (open-loop)… motor will spin")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if case .measuringLinkage = self.detectionState {
                self.detectionState = .failed("Flux linkage measurement timed out")
                self.appendLog("[DETECT] Flux linkage timeout")
            }
        }
    }

    /// Patches the MCCONF cache with FOC detection results and drivetrain params, then
    /// sends COMM_SET_MCCONF (always saves to flash). Also updates local drivetrain settings.
    func applyFOCDetection(
        r_Ω: Float, l_µH: Float, ldLqDiff_µH: Float, lambda_Wb: Float, tc_µs: Float = 1000,
        siMotorPoles: Int, siGearRatio: Float, siWheelDiameterMM: Float
    ) {
        guard isConnected else { motorLimitsSendState = .failed("Not connected"); return }
        if fwMCConfBlocked {
            motorLimitsSendState = .failed("Firmware \(localFWVersion ?? "unknown") not supported — use VESC Tool")
            return
        }
        let cache: [UInt8]? = selectedCANID.map { rawMCConfByCANID[$0] } ?? rawMCConfLocal
        guard let cache else { motorLimitsSendState = .failed("Read MCCONF first"); return }

        guard let writePayload = VESCProtocolParser.mcconfPayloadWithFOCDetection(
            fromReceivedPayload: cache,
            r_Ω: r_Ω, l_µH: l_µH, ldLqDiff_µH: ldLqDiff_µH, lambda_Wb: lambda_Wb, tc_µs: tc_µs,
            siMotorPoles: siMotorPoles,
            siGearRatio: siGearRatio,
            siWheelDiameterM: siWheelDiameterMM / 1000.0
        ) else { motorLimitsSendState = .failed("Payload build failed"); return }

        sendCommand(writePayload)

        // Update the MCCONF cache so future current-limit writes don't overwrite detection results
        var updatedCache = writePayload
        updatedCache[0] = VESCCommand.getMCConf.rawValue
        if let id = selectedCANID { rawMCConfByCANID[id] = updatedCache }
        else { rawMCConfLocal = updatedCache }

        settings.motorPolePairs = Double(siMotorPoles) / 2.0
        settings.gearRatio      = Double(siGearRatio)
        settings.wheelDiameterMM = Double(siWheelDiameterMM)
        saveSettings()

        motorLimitsSendState = .sent("Motor parameters applied & saved to flash")
        appendLog("[DETECT] FOC detection applied: R=\(String(format:"%.2f",r_Ω*1000))mΩ L=\(String(format:"%.2f",l_µH))µH λ=\(String(format:"%.4f",lambda_Wb*1000))mWb")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .sent = self.motorLimitsSendState { self.motorLimitsSendState = .idle }
        }
    }

    /// Returns drivetrain SI params from the active VESC's MCCONF cache, or nil if not cached.
    func drivetrainFromMCCONF() -> (poles: Int, gearRatio: Float, wheelDiameterMM: Float)? {
        let cache: [UInt8]? = selectedCANID.map { rawMCConfByCANID[$0] } ?? rawMCConfLocal
        guard let cache,
              let dt = VESCProtocolParser.readDrivetrainFromMCConf(payload: cache) else { return nil }
        return (dt.poles, dt.gearRatio, dt.wheelDiameterM * 1000.0)
    }

    /// Patches only si_wheel_diameter in the MCCONF cache and sends COMM_SET_MCCONF.
    /// Always updates local DrivetrainSettings. Gear ratio and all other fields are untouched.
    /// Returns (success, message) for UI feedback.
    @discardableResult
    func applyWheelDiameterCorrection(diameterMM: Float) -> (success: Bool, message: String) {
        settings.wheelDiameterMM = Double(diameterMM)
        saveSettings()

        guard isConnected else {
            return (false, "Not connected — diameter saved locally only")
        }
        guard !fwMCConfBlocked else {
            return (false, "Firmware \(localFWVersion ?? "unknown") not supported — saved locally only")
        }

        var cache: [UInt8]? = selectedCANID.map { rawMCConfByCANID[$0] } ?? rawMCConfLocal
        guard cache != nil else {
            return (false, "Read motor config first — diameter saved locally only")
        }

        guard VESCProtocolParser.patchWheelDiameter(in: &cache!, diameterM: diameterMM / 1000.0) else {
            return (false, "Payload too short — diameter saved locally only")
        }

        var writePayload = cache!
        writePayload[0] = VESCCommand.setMCConf.rawValue
        sendCommand(writePayload)

        if let id = selectedCANID { rawMCConfByCANID[id] = cache! }
        else { rawMCConfLocal = cache! }

        appendLog("[TIRE] Wheel diameter corrected to \(String(format: "%.1f", diameterMM)) mm — written to VESC flash")
        return (true, "\(String(format: "%.1f", diameterMM)) mm written to VESC")
    }

    /// Applies `profile` to every connected VESC.
    ///
    /// - `storeToFlash = true`:  sends COMM_SET_MCCONF_TEMP store=false (RAM apply) followed by
    ///   store=true (flash persist). Two packets ensure RAM is updated even on firmware 6.06+
    ///   where store=true alone only writes flash.
    ///
    /// - `storeToFlash = false`: sends COMM_SET_MCCONF_TEMP store=false (RAM-only).
    ///   forwardCAN=true so the local VESC auto-forwards to all CAN nodes.
    func applyProfile(_ profile: MotorProfile, storeToFlash: Bool = true) {
        guard isConnected else { motorLimitsSendState = .failed("Not connected"); return }

        func makePayload(store: Bool) -> [UInt8] {
            VESCProtocolParser.mcconfTempPayload(
                currentMinScale: profile.currentMinScale,
                currentMaxScale: profile.currentMaxScale,
                minERPM: profile.minERPM,
                maxERPM: profile.maxERPM,
                wattMin: profile.wattMin,
                wattMax: profile.wattMax,
                store: store,
                forwardCAN: true
            )
        }

        // Always apply to RAM first. On firmware 6.06+, store=true alone only writes flash.
        bleManager.send(VESCProtocolParser.buildPacket(payload: makePayload(store: false)))
        if storeToFlash {
            bleManager.send(VESCProtocolParser.buildPacket(payload: makePayload(store: true)))
        }

        motorProfile = profile

        let canCount = canNodes.count
        let targets = canCount > 0 ? "local + \(canCount) CAN node(s)" : "local"
        let modeTag = storeToFlash ? "flash" : "RAM"
        let msg = "[\(modeTag)] Applied to \(targets)"
        motorLimitsSendState = .sent(msg)
        appendLog("[PROFILE] \(msg)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .sent = self.motorLimitsSendState { self.motorLimitsSendState = .idle }
        }
    }

    /// Sends current motorLimits to a specific CAN node (ignores selectedCANID).
    /// Uses COMM_SET_MCCONF when that node's config is cached; falls back to COMM_SET_MCCONF_TEMP.
    func sendMotorLimitsTo(canID: Int, storeToFlash: Bool = false) {
        guard isConnected else { motorLimitsSendState = .failed("Not connected"); return }

        if let cache = rawMCConfByCANID[canID],
           let writePayload = VESCProtocolParser.mcconfPayloadForWrite(fromReceivedPayload: cache, config: motorLimits) {
            bleManager.send(VESCProtocolParser.buildForwardCAN(toID: UInt8(canID), commandPayload: writePayload))
            motorLimitsSendState = .sent("Sent to CAN #\(canID) · flash")
        } else {
            var payload: [UInt8] = [VESCCommand.setMCConfTemp.rawValue]
            payload.append(storeToFlash ? 1 : 0)
            payload.append(0)
            payload.append(1)
            payload.append(0)
            appendFloat32BE(&payload, motorLimits.phaseCurrentMax)
            appendFloat32BE(&payload, -abs(motorLimits.phaseCurrentRegen))
            appendFloat32BE(&payload, motorLimits.batteryCurrentMax)
            appendFloat32BE(&payload, min(motorLimits.batteryCurrentRegen, 0))
            appendFloat32BE(&payload, motorLimits.absCurrentMax)
            bleManager.send(VESCProtocolParser.buildForwardCAN(toID: UInt8(canID), commandPayload: payload))
            motorLimitsSendState = .sent("Sent to CAN #\(canID)\(storeToFlash ? " · saved" : "")")
        }
        saveMotorLimits()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .sent = self.motorLimitsSendState { self.motorLimitsSendState = .idle }
        }
    }

    func saveSettings() {
        if let d = try? JSONEncoder().encode(settings)     { UserDefaults.standard.set(d, forKey: "drivetrainSettings") }
    }

    func saveUISettings() {
        if let d = try? JSONEncoder().encode(uiSettings)   { UserDefaults.standard.set(d, forKey: "uiSettings") }
    }

    func saveBatteryConfig() {
        if let d = try? JSONEncoder().encode(batteryConfig) { UserDefaults.standard.set(d, forKey: "batteryConfig") }
    }

    func saveMotorLimits() {
        if let d = try? JSONEncoder().encode(motorLimits)  { UserDefaults.standard.set(d, forKey: "motorLimitsConfig") }
    }

    // MARK: - Saved Profiles

    func addProfile(_ profile: MotorProfile) {
        savedProfiles.append(profile)
        saveSavedProfiles()
    }

    func updateProfile(_ profile: MotorProfile) {
        if let idx = savedProfiles.firstIndex(where: { $0.id == profile.id }) {
            savedProfiles[idx] = profile
            saveSavedProfiles()
        }
    }

    func removeProfile(id: UUID) {
        savedProfiles.removeAll { $0.id == id }
        saveSavedProfiles()
    }

    private func saveSavedProfiles() {
        if let d = try? JSONEncoder().encode(savedProfiles) { UserDefaults.standard.set(d, forKey: "savedMotorProfiles") }
    }

    func resetPeakStats() {
        peakSpeedKMH = 0
        peakGPSSpeedKMH = 0
        peakPowerW = 0
        peakMotorCurrentA = 0
    }

    /// Sends motor settings to the active VESC.
    /// Uses COMM_SET_MCCONF (full config, always flash) when a cached MCCONF is available
    /// — this is required for observer type, FW settings, and phase regen.
    /// Falls back to COMM_SET_MCCONF_TEMP (current limits only, RAM or flash) otherwise.
    func sendMotorLimits(storeToFlash: Bool) {
        guard isConnected else { motorLimitsSendState = .failed("Not connected"); return }
        if fwMCConfBlocked {
            motorLimitsSendState = .failed("Firmware \(localFWVersion ?? "unknown") not supported — use VESC Tool")
            return
        }

        let cache: [UInt8]? = selectedCANID.map { rawMCConfByCANID[$0] } ?? rawMCConfLocal
        if let cache,
           let writePayload = VESCProtocolParser.mcconfPayloadForWrite(fromReceivedPayload: cache, config: motorLimits) {
            sendCommand(writePayload)
            saveMotorLimits()
            motorLimitsSendState = .sent("Sent & saved to flash")
        } else {
            // COMM_SET_MCCONF requires the full cached payload — raw amp limits cannot be written
            // without knowing the firmware layout. Read motor config first.
            motorLimitsSendState = .failed("Read motor config first")
        }

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

        case VESCCommand.measureRL.rawValue:
            if let result = VESCProtocolParser.parseMeasureRLResponse(payload: payload) {
                detectionState = .rlResult(r: result.r, l: result.l, ldLqDiff: result.ldLqDiff)
                appendLog("[DETECT] R=\(String(format:"%.3f",result.r*1000))mΩ  L=\(String(format:"%.2f",result.l))µH  Ld-Lq=\(String(format:"%.2f",result.ldLqDiff))µH")
            } else {
                detectionState = .failed("R/L detection failed — check motor connection")
                appendLog("[DETECT] R/L detection failed")
            }

        case VESCCommand.measureFluxLinkageOpenloop.rawValue:
            if case .measuringLinkage(let r, let l, let ldLq) = detectionState,
               let lambda = VESCProtocolParser.parseMeasureFluxLinkageOpenloopResponse(payload: payload) {
                detectionState = .complete(r: r, l: l, ldLqDiff: ldLq, lambda: lambda)
                appendLog("[DETECT] λ=\(String(format:"%.4f",lambda*1000))mWb")
            } else {
                detectionState = .failed("Flux linkage detection failed — try again with lower duty")
                appendLog("[DETECT] Flux linkage detection failed")
            }

        case 0:  // COMM_FW_VERSION
            if pendingLocalFWVersion {
                applyLocalFWVersion(payload)
                pendingLocalFWVersion = false
            } else if let nodeID = pendingFWVersionCANID {
                applyFWVersion(payload, toNodeID: nodeID)
                pendingFWVersionCANID = nil
                drainFWVersionQueue()
            }

        case VESCCommand.forwardCAN.rawValue:  // 34 — CAN-node responses come back wrapped
            guard payload.count >= 3 else { break }
            let srcID    = Int(payload[1])
            let innerCmd = payload[2]
            let inner    = Array(payload[2...])

            if innerCmd == 0,  // COMM_GET_FW_VERSION response
               let nodeID = pendingFWVersionCANID, nodeID == srcID {
                applyFWVersion(inner, toNodeID: nodeID)
                pendingFWVersionCANID = nil
                drainFWVersionQueue()
            } else if innerCmd == VESCCommand.getMCConf.rawValue {
                // MCCONF from a CAN node — force the correct source so handleMCConf
                // stores into rawMCConfByCANID[srcID] regardless of queue state.
                pendingMCConfSource = .can(srcID)
                handleMCConf(inner)
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
        localFWVersionInt = Int(major) * 100 + Int(minor)
        localFWVersion = hw.isEmpty ? "\(major).\(String(format: "%02d", minor))"
                                    : "\(major).\(String(format: "%02d", minor)) · \(hw)"
        appendLog("[FW] Local VESC firmware: \(localFWVersion!)\(fwMCConfBlocked ? " — MCCONF BLOCKED (unsupported firmware)" : "")")
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
        let wasBg = isBgFetchingMCConf
        isBgFetchingMCConf = false

        switch pendingMCConfSource {
        case .local:       rawMCConfLocal = payload
        case .can(let id): rawMCConfByCANID[id] = payload
        }
        pendingMCConfSource = .local

        // Profile fields [33-86] are at stable offsets across all firmware 6.x — read them
        // regardless of whether the full MCCONF parse succeeds. This ensures profiles can be
        // applied via COMM_SET_MCCONF_TEMP even on unsupported or mismatched firmware.
        if let prof = VESCProtocolParser.readProfileFromMCConf(payload: payload) {
            motorProfile = prof
        }

        do {
            let limits = try VESCProtocolParser.parseMCConfLimits(payload: payload)
            motorLimits = limits
            mcconfCompatWarning = nil
            saveMotorLimits()
            if !wasBg { motorLimitsReadState = .loaded }
            appendLog("[MCCONF] Loaded: phase=\(Int(limits.phaseCurrentMax))A batt=\(Int(limits.batteryCurrentMax))A regen=\(Int(limits.batteryCurrentRegen))A abs=\(Int(limits.absCurrentMax))A observer=\(limits.observerType) fzv=\(Int(limits.zeroVectorFreqHz))Hz")
        } catch PacketError.firmwareMismatch(let detail) {
            // Build the full warning, prepending firmware version if known
            let fwTag = localFWVersion.map { "Firmware: \($0)\n" } ?? ""
            mcconfCompatWarning = fwTag + detail
            // Raw payload still cached — do NOT update motorLimits with garbage values
            if !wasBg { motorLimitsReadState = .failed("Firmware layout mismatch — config locked (see banner)") }
            appendLog("[MCCONF] Firmware mismatch — offsets for FW6.05 don't match this firmware")
        } catch {
            if !wasBg { motorLimitsReadState = .failed(error.localizedDescription) }
            appendLog("[MCCONF] Parse error: \(error.localizedDescription)")
        }

        // Drain the next bg fetch after a short pause to avoid flooding BLE
        if wasBg {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.drainBgMCConfQueue()
            }
        }
    }

    private func handleCANPing(_ payload: [UInt8]) {
        let hex = payload.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        appendLog("[CAN] PING_CAN reply \(payload.count)B: \(hex)\(payload.count > 16 ? "…" : "")")
        let ids = VESCProtocolParser.parseCANPingResponse(payload: payload)
        for id in ids { mergeNodeID(id) }
        appendLog("[CAN] PING_CAN found \(ids.count) node(s): \(ids.map(String.init).joined(separator: ", "))")
        for id in ids {
            if canNodes.first(where: { $0.id == id })?.hwVersion == nil { requestFWVersion(canID: id) }
            enqueueBgMCConfFetch(id)   // auto-fetch MCCONF so profiles can be applied immediately
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
        if let d = UserDefaults.standard.data(forKey: "savedMotorProfiles"),
           let profiles = try? JSONDecoder().decode([MotorProfile].self, from: d) { savedProfiles = profiles }
        if let d = UserDefaults.standard.data(forKey: "uiSettings"),
           let ui = try? JSONDecoder().decode(UISettings.self, from: d) { uiSettings = ui }
        if let d = UserDefaults.standard.data(forKey: "batteryConfig"),
           let b = try? JSONDecoder().decode(BatteryConfig.self, from: d) { batteryConfig = b }
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
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard self.isConnected else { return }
                        // Auto-fetch local MCCONF so profile can be applied without manual read
                        self.enqueueBgMCConfFetch(nil)
                        self.pingCAN()
                        try? await Task.sleep(nanoseconds: 9_000_000_000)  // wait for 8 s scan
                        for id in self.persistedCANIDs
                            where self.canNodes.first(where: { $0.id == id })?.hwVersion == nil {
                            guard self.isConnected else { break }
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
                    self.localFWVersionInt = nil
                    self.fwVersionQueue.removeAll()
                    self.pendingFWVersionCANID = nil
                    self.pendingLocalFWVersion = false
                    self.bgMCConfQueue.removeAll()
                    self.isBgFetchingMCConf = false
                    self.rawMCConfLocal = nil
                    self.rawMCConfByCANID.removeAll()
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

        $uiSettings
            .map(\.showGPSSpeed)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled { self?.locationManager.start() }
                else       { self?.locationManager.stop() }
            }
            .store(in: &cancellables)

        locationManager.$speedKMH
            .receive(on: RunLoop.main)
            .sink { [weak self] speed in
                guard let self else { return }
                self.gpsSpeedKMH = speed
                if let s = speed { self.peakGPSSpeedKMH = max(self.peakGPSSpeedKMH, s) }
            }
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

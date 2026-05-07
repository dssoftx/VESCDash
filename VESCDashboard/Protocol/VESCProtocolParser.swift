import Foundation

// MARK: - VESC Packet Format
//
// Short packet (payload ≤ 255 bytes):
//   [0x02] [len: u8] [payload…] [crc_hi: u8] [crc_lo: u8] [0x03]
//
// Long packet (payload 256–512 bytes):
//   [0x03] [len_hi: u8] [len_lo: u8] [payload…] [crc_hi: u8] [crc_lo: u8] [0x03]
//
// CRC: CRC-CCITT (poly=0x1021, init=0x0000), computed over payload bytes only.
// Note: 0x03 serves as both the long-packet start byte and the universal stop byte.

// MARK: - COMM_GET_VALUES Response Payload Layout
//
// Byte offsets within the payload (after the command byte at [0]):
//   [0]      command = 4 (COMM_GET_VALUES)
//   [1-2]    temp_fet    : int16  / 10.0   → °C
//   [3-4]    temp_motor  : int16  / 10.0   → °C
//   [5-8]    avg_motor_current : int32 / 100.0  → A
//   [9-12]   avg_input_current : int32 / 100.0  → A
//   [13-16]  avg_id      : int32 / 100.0   → A
//   [17-20]  avg_iq      : int32 / 100.0   → A
//   [21-22]  duty_cycle  : int16 / 1000.0  → fraction
//   [23-26]  rpm         : int32           → ERPM
//   [27-28]  v_in        : int16 / 10.0    → V
//   [29-32]  amp_hours   : int32 / 10000.0 → Ah
//   [33-36]  amp_hours_charged : int32 / 10000.0 → Ah
//   [37-40]  watt_hours  : int32 / 10000.0 → Wh
//   [41-44]  watt_hours_charged : int32 / 10000.0 → Wh
//   [45-48]  tachometer  : int32
//   [49-52]  tachometer_abs : int32
//   [53]     fault_code  : uint8

enum VESCCommand: UInt8 {
    case getValues                  = 4
    case setCurrent                 = 6
    case setRPM                     = 8
    case getMCConf                  = 14   // Read full motor configuration struct
    case setMCConf                  = 13   // Write full motor configuration (always saves to flash)
    case alive                      = 30
    case forwardCAN                 = 34   // Forward next command to a CAN bus node
    case setMCConfTemp              = 48   // Write current/voltage limits (RAM or flash)
    case getValuesSelective         = 50
    case pingCAN                    = 62   // Discover all CAN-connected VESCs
    case measureRL                  = 25   // Measure motor resistance & inductance
    case measureFluxLinkageOpenloop = 57   // Open-loop spin to measure flux linkage
}

enum PacketError: Error, LocalizedError {
    case invalidStartByte(UInt8)
    case insufficientData(needed: Int, have: Int)
    case crcMismatch(expected: UInt16, received: UInt16)
    case invalidEndByte(UInt8)
    case unexpectedCommand(UInt8)
    case payloadTooShort(needed: Int, have: Int)

    var errorDescription: String? {
        switch self {
        case .invalidStartByte(let b):      return "Invalid start byte 0x\(String(b, radix: 16))"
        case .insufficientData(let n, let h): return "Need \(n) bytes, have \(h)"
        case .crcMismatch(let e, let r):    return "CRC mismatch: expected 0x\(String(e, radix: 16)) got 0x\(String(r, radix: 16))"
        case .invalidEndByte(let b):        return "Invalid end byte 0x\(String(b, radix: 16))"
        case .unexpectedCommand(let c):     return "Unexpected command \(c)"
        case .payloadTooShort(let n, let h): return "Payload too short: need \(n), have \(h)"
        }
    }
}

enum VESCProtocolParser {

    // MARK: - CRC-CCITT

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        crc16(bytes[...])
    }

    // MARK: - Packet Building

    /// Wraps `payload` in VESC framing: start byte, length, payload, CRC, stop byte.
    static func buildPacket(payload: [UInt8]) -> [UInt8] {
        var pkt = [UInt8]()
        let len = payload.count

        if len <= 255 {
            pkt.append(0x02)
            pkt.append(UInt8(len))
        } else {
            pkt.append(0x03)
            pkt.append(UInt8(len >> 8))
            pkt.append(UInt8(len & 0xFF))
        }

        pkt.append(contentsOf: payload)

        let crc = crc16(payload)
        pkt.append(UInt8(crc >> 8))
        pkt.append(UInt8(crc & 0xFF))
        pkt.append(0x03)

        return pkt
    }

    static func buildGetValuesCommand() -> [UInt8] {
        buildPacket(payload: [VESCCommand.getValues.rawValue])
    }

    static func buildAliveCommand() -> [UInt8] {
        buildPacket(payload: [VESCCommand.alive.rawValue])
    }

    // MARK: - COMM_SET_MCCONF_TEMP (cmd 48) — firmware 6.x format
    //
    // Payload layout (8 parameters, all IEEE-754 float32 big-endian):
    //   [0]    cmd = 48
    //   [1]    store                 : u8 bool — 1 = save to flash, 0 = RAM only (lost on reboot)
    //   [2]    forward_can           : u8 bool — 1 = local VESC auto-forwards to all CAN nodes
    //   [3]    ack                   : u8 bool — 1 = VESC replies with echo packet
    //   [4]    divide_by_controllers : u8 bool — 1 = watt limits ÷ number of CAN nodes
    //   [5-8]  l_current_min_scale   : float32 (0.0 – 1.0) — braking current fraction
    //   [9-12] l_current_max_scale   : float32 (0.0 – 1.0) — acceleration current fraction
    //  [13-16] l_min_erpm            : float32 (negative)  — reverse speed limit
    //  [17-20] l_max_erpm            : float32 (positive)  — forward speed limit
    //  [21-24] l_min_duty            : float32 (negative)  — min duty cycle (e.g. -0.95)
    //  [25-28] l_max_duty            : float32 (positive)  — max duty cycle (e.g.  0.95)
    //  [29-32] l_watt_min            : float32 (negative)  — max regen power (W)
    //  [33-36] l_watt_max            : float32 (positive)  — max discharge power (W)

    /// Raw COMM_SET_MCCONF_TEMP payload (no packet framing).
    /// Applies a full motor profile to RAM and/or flash. Pass to buildPacket() for the local VESC.
    /// Set forwardCAN=true to have the local VESC auto-forward to all CAN nodes (no manual iteration needed).
    static func mcconfTempPayload(
        currentMinScale: Float,
        currentMaxScale: Float,
        minERPM: Float,
        maxERPM: Float,
        minDuty: Float = -0.95,
        maxDuty: Float = 0.95,
        wattMin: Float,
        wattMax: Float,
        store: Bool,
        forwardCAN: Bool = false
    ) -> [UInt8] {
        var p: [UInt8] = [VESCCommand.setMCConfTemp.rawValue,
                          store ? 1 : 0,
                          forwardCAN ? 1 : 0,
                          0,  // ack = false
                          0]  // divide_by_controllers = false
        appendFloat32BE(&p, max(0, min(1, currentMinScale)))
        appendFloat32BE(&p, max(0, min(1, currentMaxScale)))
        appendFloat32BE(&p, minERPM)
        appendFloat32BE(&p, maxERPM)
        appendFloat32BE(&p, minDuty)
        appendFloat32BE(&p, maxDuty)
        appendFloat32BE(&p, wattMin)
        appendFloat32BE(&p, wattMax)
        return p
    }

    // MARK: - COMM_FORWARD_CAN (cmd 34)
    //
    // Wraps a raw command payload for delivery to a specific CAN bus node.
    // The master VESC (connected via BLE) strips cmd 34 and forwards the inner
    // payload over CAN. Responses return as plain command replies (no CAN wrapper).
    //
    // Payload: [34] [can_id: u8] [inner_command_payload…]

    /// Builds a framed COMM_FORWARD_CAN packet targeting `toID`.
    static func buildForwardCAN(toID: UInt8, commandPayload: [UInt8]) -> [UInt8] {
        var payload: [UInt8] = [VESCCommand.forwardCAN.rawValue, toID]
        payload.append(contentsOf: commandPayload)
        return buildPacket(payload: payload)
    }

    // MARK: - COMM_PING_CAN (cmd 81)
    //
    // Request: single-byte payload [81]. The master VESC pings each CAN ID 0–253
    // and replies with a list of IDs that responded.
    //
    // Response payload: [81] [id0: u8] [id1: u8] … [idN: u8]
    // Note: no count byte — all bytes after the command byte are IDs (matches VESC Tool source).

    static func buildPingCANCommand() -> [UInt8] {
        buildPacket(payload: [VESCCommand.pingCAN.rawValue])
    }

    /// Returns the CAN IDs of discovered nodes from a COMM_PING_CAN response.
    static func parseCANPingResponse(payload: [UInt8]) -> [Int] {
        guard !payload.isEmpty, payload[0] == VESCCommand.pingCAN.rawValue else { return [] }
        return payload.dropFirst().map { Int($0) }
    }

    // MARK: - COMM_GET_MCCONF parse (cmd 14)
    //
    // Firmware 6.05 MCCONF payload layout (offsets within the full payload array):
    //
    //   [0]       cmd = 14
    //   [1-4]     config signature (uint32 BE) — reused verbatim in COMM_SET_MCCONF
    //   [5-8]     enum header (pwm_mode, comm_mode, motor_type, sensor_mode — 1 byte each)
    //   [9-12]    l_current_max     : DOUBLE32_AUTO ≡ IEEE-754 float32 BE  → A
    //   [13-16]   l_current_min     : float32 BE  → A (negative = phase regen)
    //   [17-20]   l_in_current_max  : float32 BE  → A
    //   [21-24]   l_in_current_min  : float32 BE  → A (negative = battery regen)
    //   [25-28]   l_in_current_map_start/filter (2×int16, skipped)
    //   [29-32]   l_abs_current_max : float32 BE  → A
    //   …
    //   [132-135] foc_f_zv          : float32 BE  → Hz (zero-vector switching freq)
    //   …
    //   [251]     foc_observer_type : uint8   (0=Ortega, 1=MXLemming, …, 3=MXLemming+λ)
    //   …
    //   [307-310] foc_fw_current_max: float32 BE  → A (0 = FW disabled)
    //   [311-312] foc_fw_duty_start : int16 / 10000 → fraction (e.g. 9000 = 0.90)

    static func parseMCConfLimits(payload: [UInt8]) throws -> MotorLimitsConfig {
        guard payload.count >= 33, payload[0] == VESCCommand.getMCConf.rawValue else {
            throw PacketError.payloadTooShort(needed: 33, have: payload.count)
        }
        var c = MotorLimitsConfig()
        c.phaseCurrentMax     = float32BEAt(payload,  9)
        c.phaseCurrentRegen   = float32BEAt(payload, 13)
        c.batteryCurrentMax   = float32BEAt(payload, 17)
        c.batteryCurrentRegen = float32BEAt(payload, 21)
        c.absCurrentMax       = float32BEAt(payload, 29)
        if payload.count >= 136 {
            c.zeroVectorFreqHz = float32BEAt(payload, 132)
        }
        if payload.count >= 252 {
            c.observerType = Int(payload[251])
        }
        if payload.count >= 313 {
            c.fieldWeakeningCurrentMax = float32BEAt(payload, 307)
            c.fieldWeakeningDutyStart  = Float(int16At(payload, 311)) / 10000.0
        }
        return c
    }

    // MARK: - COMM_SET_MCCONF (cmd 13)
    //
    // Takes the raw payload received from COMM_GET_MCCONF (including cmd byte and
    // the firmware signature), modifies the motor-config fields in place, and returns
    // the modified payload array ready to pass to sendCommand(). The firmware validates
    // the signature, so we must preserve the bytes we received unchanged except for the
    // fields we intentionally overwrite.
    //
    // Caller note: pass the returned payload to sendCommand(), not bleManager.send() —
    // sendCommand() handles FORWARD_CAN wrapping for CAN node targets.

    static func mcconfPayloadForWrite(
        fromReceivedPayload payload: [UInt8],
        config: MotorLimitsConfig
    ) -> [UInt8]? {
        guard payload.count >= 33, payload[0] == VESCCommand.getMCConf.rawValue else {
            return nil
        }
        var p = payload
        p[0] = VESCCommand.setMCConf.rawValue   // flip cmd 14 → 13

        setFloat32BE(&p,  9, config.phaseCurrentMax)
        setFloat32BE(&p, 13, -abs(config.phaseCurrentRegen))
        setFloat32BE(&p, 17, config.batteryCurrentMax)
        setFloat32BE(&p, 21, min(config.batteryCurrentRegen, 0))
        setFloat32BE(&p, 29, config.absCurrentMax)

        if p.count >= 136 {
            setFloat32BE(&p, 132, config.zeroVectorFreqHz)
        }
        if p.count >= 252 {
            p[251] = UInt8(max(0, min(6, config.observerType)))
        }
        if p.count >= 313 {
            setFloat32BE(&p, 307, config.fieldWeakeningCurrentMax)
            setInt16BE(&p, 311, Int16(config.fieldWeakeningDutyStart * 10000))
        }
        return p
    }

    // MARK: - COMM_DETECT_MOTOR_R_L (cmd 25)
    //
    // Request: [25]  (no parameters)
    // Response: [25][r: int32/1e6 Ω][l: int32/1e3 µH][ld_lq_diff: int32/1e3 µH]
    //
    // r=0 and l=0 means detection failed (motor not connected / too noisy).

    static func buildMeasureRLCommand() -> [UInt8] {
        buildPacket(payload: [VESCCommand.measureRL.rawValue])
    }

    /// Returns (r_Ω, l_µH, ldLqDiff_µH) or nil if the payload is invalid / detection failed.
    static func parseMeasureRLResponse(payload: [UInt8]) -> (r: Float, l: Float, ldLqDiff: Float)? {
        guard payload.count >= 13, payload[0] == VESCCommand.measureRL.rawValue else { return nil }
        let r         = Float(int32BEAt(payload, 1)) / 1_000_000.0
        let l         = Float(int32BEAt(payload, 5)) / 1_000.0
        let ldLqDiff  = Float(int32BEAt(payload, 9)) / 1_000.0
        guard r > 1e-9 || l > 1e-9 else { return nil }
        return (r, l, ldLqDiff)
    }

    // MARK: - COMM_DETECT_MOTOR_FLUX_LINKAGE_OPENLOOP (cmd 57)
    //
    // Request:  [57][current/1e3 A][erpmPerSec/1e3][lowDuty/1e3][resistance/1e6 Ω][inductance/1e8 H]
    // Response: [57][flux_linkage: int32/1e7 Wb]
    //
    // The motor will spin; caller should warn the user.

    /// - Parameters:
    ///   - current:     Detection current in Amperes.
    ///   - erpmPerSec:  Open-loop ERPM ramp rate (default ≈ 700).
    ///   - lowDuty:     Starting duty cycle (default 0.06).
    ///   - resistance:  Motor phase resistance in Ohms (from measureRL).
    ///   - inductance:  Motor inductance in Henries (l_µH / 1e6).
    static func buildMeasureFluxLinkageOpenloopCommand(
        current: Float, erpmPerSec: Float, lowDuty: Float,
        resistance: Float, inductance: Float
    ) -> [UInt8] {
        var payload: [UInt8] = [VESCCommand.measureFluxLinkageOpenloop.rawValue]
        appendInt32BE(&payload, Int32(current    * 1_000))
        appendInt32BE(&payload, Int32(erpmPerSec * 1_000))
        appendInt32BE(&payload, Int32(lowDuty    * 1_000))
        appendInt32BE(&payload, Int32(resistance * 1_000_000))
        appendInt32BE(&payload, Int32(inductance * 100_000_000))
        return buildPacket(payload: payload)
    }

    /// Returns flux linkage in Wb, or nil if detection failed.
    static func parseMeasureFluxLinkageOpenloopResponse(payload: [UInt8]) -> Float? {
        guard payload.count >= 5,
              payload[0] == VESCCommand.measureFluxLinkageOpenloop.rawValue else { return nil }
        let lambda = Float(int32BEAt(payload, 1)) / 10_000_000.0
        return lambda > 1e-9 ? lambda : nil
    }

    // MARK: - MCCONF read helpers for drivetrain / FOC params
    //
    // Byte offsets (verified against firmware 6.05 parameters_mcconf.xml via SerOrder):
    //   l_min_vin           [53-56]    float32 — absolute hardware min voltage (hard cutoff)
    //   l_max_vin           [57-60]    float32 — absolute hardware max voltage
    //   l_battery_cut_start [61-64]    float32 — voltage to start linearly reducing output
    //   l_battery_cut_end   [65-68]    float32 — voltage to stop output entirely
    //   foc_current_kp      [124-127]  float32
    //   foc_current_ki      [128-131]  float32
    //   foc_f_zv            [132-135]  float32 (Hz)
    //   foc_motor_l         [158-161]  float32 (H)
    //   foc_motor_ld_lq_diff[162-165]  float32 (H)
    //   foc_motor_r         [166-169]  float32 (Ω)
    //   foc_motor_flux_linkage [170-173] float32 (Wb)
    //   foc_observer_gain   [174-177]  float32 (raw × 1e6)
    //   si_motor_poles      [442]      uint8   (total poles = 2 × pole_pairs)
    //   si_gear_ratio       [443-446]  float32
    //   si_wheel_diameter   [447-450]  float32 (metres)

    /// Reads drivetrain SI params from a raw COMM_GET_MCCONF payload.
    static func readDrivetrainFromMCConf(payload: [UInt8]) -> (poles: Int, gearRatio: Float, wheelDiameterM: Float)? {
        guard payload.count >= 452 else { return nil }
        return (Int(payload[442]), float32BEAt(payload, 443), float32BEAt(payload, 447))
    }

    /// Patches a COMM_GET_MCCONF payload with FOC detection results and returns a ready-to-send
    /// COMM_SET_MCCONF payload.  The firmware signature bytes are preserved unchanged.
    ///
    /// - Parameters:
    ///   - r_Ω:              Phase resistance (Ω).
    ///   - l_µH:             Phase inductance (µH).
    ///   - ldLqDiff_µH:      Ld-Lq inductance difference (µH).
    ///   - lambda_Wb:        Flux linkage (Wb).
    ///   - tc_µs:            Current controller time constant (µs, default 1000).
    ///   - siMotorPoles:     Total pole count (= 2 × pole pairs).
    ///   - siGearRatio:      Gear ratio (raw, 0 = direct drive).
    ///   - siWheelDiameterM: Wheel diameter in metres.
    static func mcconfPayloadWithFOCDetection(
        fromReceivedPayload payload: [UInt8],
        r_Ω: Float, l_µH: Float, ldLqDiff_µH: Float, lambda_Wb: Float, tc_µs: Float,
        siMotorPoles: Int, siGearRatio: Float, siWheelDiameterM: Float,
        batteryMinVin: Float? = nil,
        batteryMaxVin: Float? = nil,
        batteryCutStart: Float? = nil,
        batteryCutEnd: Float? = nil
    ) -> [UInt8]? {
        guard payload.count >= 33, payload[0] == VESCCommand.getMCConf.rawValue else { return nil }
        var p = payload
        p[0] = VESCCommand.setMCConf.rawValue

        let l_H     = l_µH / 1_000_000.0
        let ldLq_H  = ldLqDiff_µH / 1_000_000.0
        let bw      = 1.0 / (tc_µs * 1e-6)
        let kp      = Float(l_H * bw)
        let ki      = Float(r_Ω * bw)
        let obsgain = Float(1e3 / (lambda_Wb * lambda_Wb))

        // Battery voltage cutoffs (offsets verified against firmware 6.05)
        if p.count >= 70 {
            if let v = batteryMinVin   { setFloat32BE(&p, 53, v) }
            if let v = batteryMaxVin   { setFloat32BE(&p, 57, v) }
            if let v = batteryCutStart { setFloat32BE(&p, 61, v) }
            if let v = batteryCutEnd   { setFloat32BE(&p, 65, v) }
        }

        if p.count >= 175 {
            setFloat32BE(&p, 124, kp)
            setFloat32BE(&p, 128, ki)
            setFloat32BE(&p, 158, l_H)
            setFloat32BE(&p, 162, ldLq_H)
            setFloat32BE(&p, 166, r_Ω)
            setFloat32BE(&p, 170, lambda_Wb)
            setFloat32BE(&p, 174, obsgain)
        }
        if p.count >= 452 {
            p[442] = UInt8(max(2, min(254, siMotorPoles)))
            setFloat32BE(&p, 443, siGearRatio)
            setFloat32BE(&p, 447, siWheelDiameterM)
        }
        return p
    }

    // MARK: - Motor Profile read/write (cmd 14 / 13)
    //
    // Firmware 6.05 offsets (verified via parameters_mcconf.xml SerOrder + vTx):
    //   l_min_erpm          [33-36]   DOUBLE32_AUTO / float32 BE (ERPM, negative = reverse)
    //   l_max_erpm          [37-40]   DOUBLE32_AUTO / float32 BE (ERPM, forward)
    //   l_watt_max          [74-77]   DOUBLE32_AUTO / float32 BE (W; large default ≈ disabled)
    //   l_watt_min          [78-81]   DOUBLE32_AUTO / float32 BE (W, negative; large neg ≈ disabled)
    //   l_current_max_scale [82-83]   DOUBLE16 / 10000 (0.0–1.0 accel scale)
    //   l_current_min_scale [84-85]   DOUBLE16 / 10000 (0.0–1.0 braking scale)

    static func readProfileFromMCConf(payload: [UInt8]) -> MotorProfile? {
        guard payload.count >= 87, payload[0] == VESCCommand.getMCConf.rawValue else { return nil }
        var p = MotorProfile()
        p.minERPM         = float32BEAt(payload, 33)
        p.maxERPM         = float32BEAt(payload, 37)
        p.wattMax         = float32BEAt(payload, 74)
        p.wattMin         = float32BEAt(payload, 78)
        p.currentMaxScale = Float(int16At(payload, 82)) / 10_000.0
        p.currentMinScale = Float(int16At(payload, 84)) / 10_000.0
        return p
    }

    static func mcconfPayloadWithProfile(
        fromReceivedPayload payload: [UInt8],
        profile: MotorProfile
    ) -> [UInt8]? {
        guard payload.count >= 87, payload[0] == VESCCommand.getMCConf.rawValue else { return nil }
        var p = payload
        p[0] = VESCCommand.setMCConf.rawValue
        setFloat32BE(&p, 33, profile.minERPM)
        setFloat32BE(&p, 37, profile.maxERPM)
        setFloat32BE(&p, 74, profile.wattMax)
        setFloat32BE(&p, 78, profile.wattMin)
        setInt16BE(&p, 82, Int16(clamping: Int(profile.currentMaxScale * 10_000)))
        setInt16BE(&p, 84, Int16(clamping: Int(profile.currentMinScale * 10_000)))
        return p
    }

    // MARK: - Byte helpers

    static func float32BEAt(_ b: [UInt8], _ i: Int) -> Float {
        let bits = (UInt32(b[i]) << 24) | (UInt32(b[i+1]) << 16) |
                   (UInt32(b[i+2]) << 8) | UInt32(b[i+3])
        return Float(bitPattern: bits)
    }

    static func setFloat32BE(_ buf: inout [UInt8], _ i: Int, _ value: Float) {
        let bits = value.bitPattern
        buf[i]   = UInt8((bits >> 24) & 0xFF)
        buf[i+1] = UInt8((bits >> 16) & 0xFF)
        buf[i+2] = UInt8((bits >> 8)  & 0xFF)
        buf[i+3] = UInt8( bits        & 0xFF)
    }

    static func setInt16BE(_ buf: inout [UInt8], _ i: Int, _ value: Int16) {
        let v = UInt16(bitPattern: value)
        buf[i]   = UInt8(v >> 8)
        buf[i+1] = UInt8(v & 0xFF)
    }

    static func int32BEAt(_ b: [UInt8], _ i: Int) -> Int32 {
        let v = (UInt32(b[i]) << 24) | (UInt32(b[i+1]) << 16) |
                (UInt32(b[i+2]) << 8)  |  UInt32(b[i+3])
        return Int32(bitPattern: v)
    }

    static func appendFloat32BE(_ buf: inout [UInt8], _ value: Float) {
        let bits = value.bitPattern
        buf.append(UInt8((bits >> 24) & 0xFF))
        buf.append(UInt8((bits >> 16) & 0xFF))
        buf.append(UInt8((bits >> 8)  & 0xFF))
        buf.append(UInt8( bits        & 0xFF))
    }

    static func appendInt32BE(_ buf: inout [UInt8], _ value: Int32) {
        let v = UInt32(bitPattern: value)
        buf.append(UInt8((v >> 24) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8((v >> 8)  & 0xFF))
        buf.append(UInt8( v        & 0xFF))
    }

    // MARK: - Packet Parsing

    /// Validates framing and CRC, returns the raw payload slice (including command byte).
    static func parsePacket(bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 5 else {
            throw PacketError.insufficientData(needed: 5, have: bytes.count)
        }

        var i = 0
        let start = bytes[i]; i += 1

        let payloadLen: Int
        if start == 0x02 {
            payloadLen = Int(bytes[i]); i += 1
        } else if start == 0x03 {
            let hi = Int(bytes[i]); i += 1
            let lo = Int(bytes[i]); i += 1
            payloadLen = (hi << 8) | lo
        } else {
            throw PacketError.invalidStartByte(start)
        }

        let needed = i + payloadLen + 2 + 1
        guard bytes.count >= needed else {
            throw PacketError.insufficientData(needed: needed, have: bytes.count)
        }

        let payloadSlice = bytes[i ..< (i + payloadLen)]
        i += payloadLen

        let rxCRC = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
        i += 2
        let calcCRC = crc16(payloadSlice)
        guard rxCRC == calcCRC else {
            throw PacketError.crcMismatch(expected: calcCRC, received: rxCRC)
        }

        guard bytes[i] == 0x03 else {
            throw PacketError.invalidEndByte(bytes[i])
        }

        return Array(payloadSlice)
    }

    // MARK: - Telemetry Parsing

    static func parseTelemetry(payload: [UInt8]) throws -> TelemetryData {
        guard !payload.isEmpty, payload[0] == VESCCommand.getValues.rawValue else {
            throw PacketError.unexpectedCommand(payload.first ?? 0)
        }
        // Minimum 54 bytes: 1 cmd + 53 data
        guard payload.count >= 54 else {
            throw PacketError.payloadTooShort(needed: 54, have: payload.count)
        }

        var d = TelemetryData()
        var i = 1

        d.mosfetTemperature = Float(int16At(payload, i)) / 10.0;  i += 2
        d.motorTemperature  = Float(int16At(payload, i)) / 10.0;  i += 2
        d.motorCurrent      = Float(int32At(payload, i)) / 100.0; i += 4
        d.batteryCurrent    = Float(int32At(payload, i)) / 100.0; i += 4
        d.avgId             = Float(int32At(payload, i)) / 100.0; i += 4
        d.avgIq             = Float(int32At(payload, i)) / 100.0; i += 4
        d.dutyCycle         = Float(int16At(payload, i)) / 1000.0; i += 2
        d.rpm               = int32At(payload, i);                 i += 4
        d.inputVoltage      = Float(int16At(payload, i)) / 10.0;   i += 2
        d.ampHours          = Float(int32At(payload, i)) / 10000.0; i += 4
        d.ampHoursCharged   = Float(int32At(payload, i)) / 10000.0; i += 4
        d.wattHours         = Float(int32At(payload, i)) / 10000.0; i += 4
        d.wattHoursCharged  = Float(int32At(payload, i)) / 10000.0; i += 4
        d.tachometer        = int32At(payload, i); i += 4
        d.tachometerAbs     = int32At(payload, i); i += 4
        d.faultCode         = payload[i]
        d.timestamp         = Date()

        return d
    }

    // MARK: - Byte Readers (big-endian, signed)

    private static func int16At(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: (UInt16(b[i]) << 8) | UInt16(b[i + 1]))
    }

    private static func int32At(_ b: [UInt8], _ i: Int) -> Int32 {
        let v = (UInt32(b[i]) << 24) | (UInt32(b[i+1]) << 16) |
                (UInt32(b[i+2]) << 8)  |  UInt32(b[i+3])
        return Int32(bitPattern: v)
    }
}

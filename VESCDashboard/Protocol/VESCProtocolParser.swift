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
    case getValues          = 4
    case setCurrent         = 6
    case setRPM             = 8
    case getMCConf          = 14   // Read full motor configuration struct
    case alive              = 30
    case forwardCAN         = 34   // Forward next command to a CAN bus node
    case setMCConfTemp      = 48   // Write current/voltage limits (RAM or flash)
    case pingCAN            = 62   // Discover all CAN-connected VESCs
    case getValuesSelective = 50
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

    // MARK: - COMM_SET_MCCONF_TEMP (cmd 64)
    //
    // Payload layout:
    //   [0]    cmd = 64
    //   [1]    store       : u8 bool  — 1 = save to VESC flash, 0 = RAM only
    //   [2]    forward_can : u8 bool  — 0 = local VESC only
    //   [3]    ack         : u8 bool  — 1 = VESC replies with echo packet
    //   [4]    divide_by_controllers : u8 bool — 0 = use values as-is
    //   [5-8]  l_current_max  : IEEE-754 float32 big-endian  → max phase amps
    //   [9-12] l_current_min  : IEEE-754 float32 big-endian  → min phase amps (negative = regen braking)
    //  [13-16] l_in_current_max : float32  → max battery amps
    //  [17-20] l_in_current_min : float32  → min battery amps (negative = regen)
    //  [21-24] l_abs_current_max : float32 → absolute peak cutoff

    /// Builds a COMM_SET_MCCONF_TEMP packet.
    /// - Parameters:
    ///   - phaseMax:  Max motor phase current (A, positive).
    ///   - battMax:   Max battery draw current (A, positive).
    ///   - battMin:   Max regen current back into battery (A, **negative**, e.g. -12).
    ///   - absMax:    Absolute peak current cutoff (A, positive).
    ///   - store:     If true, VESC saves limits to flash (survives power cycle).
    static func buildSetMCConfTemp(
        phaseMax: Float,
        battMax: Float,
        battMin: Float,
        absMax: Float,
        store: Bool
    ) -> [UInt8] {
        var payload: [UInt8] = [VESCCommand.setMCConfTemp.rawValue]
        payload.append(store ? 1 : 0)   // store to flash
        payload.append(0)               // forward_can = false
        payload.append(1)               // ack = request echo back
        payload.append(0)               // divide_by_controllers = false
        appendFloat32BE(&payload, phaseMax)
        appendFloat32BE(&payload, -abs(phaseMax))  // l_current_min mirrors max
        appendFloat32BE(&payload, battMax)
        appendFloat32BE(&payload, min(battMin, 0)) // enforce negative
        appendFloat32BE(&payload, absMax)
        return buildPacket(payload: payload)
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

    // MARK: - COMM_GET_MCCONF partial parse (cmd 14)
    //
    // The full MCCONF struct is 150+ bytes. We only need the first 5 current-limit
    // fields. Firmware 5.x/6.x encodes all limit fields as IEEE-754 float32 BE and
    // includes 8 bytes of enum header (4 enums × 2 bytes each) after the cmd byte.
    //
    // Payload layout (firmware 5.x/6.x):
    //   [0]      cmd = 14
    //   [1-8]    enum header (pwm_mode, comm_mode, motor_type, sensor_mode — 2 bytes each)
    //   [9-12]   l_current_max         : float32 BE  → A
    //   [13-16]  l_current_min         : float32 BE  → A (negative, mirrors max)
    //   [17-20]  l_in_current_max      : float32 BE  → A
    //   [21-24]  l_in_current_min      : float32 BE  → A (negative)
    //   [25-28]  l_slow_abs_current_max: float32 BE  → A (firmware 5.x/6.x extra field)
    //   [29-32]  l_abs_current_max     : float32 BE  → A

    static func parseMCConfLimits(payload: [UInt8]) throws -> MotorLimitsConfig {
        guard payload.count >= 33, payload[0] == VESCCommand.getMCConf.rawValue else {
            throw PacketError.payloadTooShort(needed: 33, have: payload.count)
        }
        var c = MotorLimitsConfig()
        c.phaseCurrentMax     = float32BEAt(payload,  9)
        // l_current_min at [13..16] mirrors phaseMax as negative — not stored separately
        c.batteryCurrentMax   = float32BEAt(payload, 17)
        c.batteryCurrentRegen = float32BEAt(payload, 21)
        // [25-28] is l_slow_abs_current_max — present in firmware 5.x/6.x, skipped
        c.absCurrentMax       = float32BEAt(payload, 29)
        return c
    }

    private static func float32BEAt(_ b: [UInt8], _ i: Int) -> Float {
        let bits = (UInt32(b[i]) << 24) | (UInt32(b[i+1]) << 16) |
                   (UInt32(b[i+2]) << 8) | UInt32(b[i+3])
        return Float(bitPattern: bits)
    }

    // Appends a 32-bit IEEE-754 float in big-endian byte order.
    private static func appendFloat32BE(_ buf: inout [UInt8], _ value: Float) {
        let bits = value.bitPattern
        buf.append(UInt8((bits >> 24) & 0xFF))
        buf.append(UInt8((bits >> 16) & 0xFF))
        buf.append(UInt8((bits >> 8)  & 0xFF))
        buf.append(UInt8( bits        & 0xFF))
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

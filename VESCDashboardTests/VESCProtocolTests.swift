import XCTest
@testable import VESCDashboard

final class VESCProtocolTests: XCTestCase {

    // MARK: - CRC

    func testCRC16KnownValue() {
        // VESC uses CRC-CCITT/XModem: poly=0x1021, init=0x0000 (no bit reflection)
        // Known vector for "123456789" = 0x31C3 (not 0x29B1 which is the init=0xFFFF variant)
        let input: [UInt8] = Array("123456789".utf8)
        XCTAssertEqual(VESCProtocolParser.crc16(input), 0x31C3)
    }

    func testCRC16EmptyData() {
        XCTAssertEqual(VESCProtocolParser.crc16([]), 0x0000)
    }

    // MARK: - Packet Round-trip

    func testShortPacketRoundTrip() throws {
        let payload: [UInt8] = [0x04, 0x01, 0x02, 0x03]
        let packet  = VESCProtocolParser.buildPacket(payload: payload)
        let decoded = try VESCProtocolParser.parsePacket(bytes: packet)
        XCTAssertEqual(decoded, payload)
    }

    func testGetValuesCommandFraming() throws {
        let packet = VESCProtocolParser.buildGetValuesCommand()
        // [0x02, 0x01, 0x04, crc_h, crc_l, 0x03]
        XCTAssertEqual(packet.first,  0x02)
        XCTAssertEqual(packet[1],     0x01)  // length = 1
        XCTAssertEqual(packet[2],     0x04)  // COMM_GET_VALUES
        XCTAssertEqual(packet.last,   0x03)
        XCTAssertEqual(packet.count,  6)

        let decoded = try VESCProtocolParser.parsePacket(bytes: packet)
        XCTAssertEqual(decoded, [0x04])
    }

    func testCRCMismatchThrows() {
        var packet = VESCProtocolParser.buildGetValuesCommand()
        packet[3] ^= 0xFF // corrupt CRC high byte
        XCTAssertThrowsError(try VESCProtocolParser.parsePacket(bytes: packet))
    }

    func testInvalidStartByteThrows() {
        let badPacket: [UInt8] = [0x01, 0x01, 0x04, 0x00, 0x00, 0x03]
        XCTAssertThrowsError(try VESCProtocolParser.parsePacket(bytes: badPacket))
    }

    // MARK: - Telemetry Parsing

    func testTelemetryRoundTrip() throws {
        let simulator = MockVESCSimulator()

        // Build a known TelemetryData and encode → decode
        var original = TelemetryData()
        original.mosfetTemperature = 45.6
        original.motorTemperature  = 78.9
        original.motorCurrent      = 31.25
        original.batteryCurrent    = 24.0
        original.dutyCycle         = 0.65
        original.rpm               = 9800
        original.inputVoltage      = 41.5
        original.faultCode         = 0

        // Use MockVESCSimulator encoder
        let payload = simulator.buildTelemetryPayload(from: original)
        let decoded = try VESCProtocolParser.parseTelemetry(payload: payload)

        XCTAssertEqual(decoded.mosfetTemperature, original.mosfetTemperature, accuracy: 0.1)
        XCTAssertEqual(decoded.motorTemperature,  original.motorTemperature,  accuracy: 0.1)
        XCTAssertEqual(decoded.motorCurrent,      original.motorCurrent,      accuracy: 0.01)
        XCTAssertEqual(decoded.batteryCurrent,    original.batteryCurrent,    accuracy: 0.01)
        XCTAssertEqual(decoded.dutyCycle,         original.dutyCycle,         accuracy: 0.001)
        XCTAssertEqual(decoded.rpm,               original.rpm)
        XCTAssertEqual(decoded.inputVoltage,      original.inputVoltage,      accuracy: 0.1)
        XCTAssertEqual(decoded.faultCode,         original.faultCode)
    }

    func testTelemetryPayloadTooShortThrows() {
        let tooShort: [UInt8] = [0x04, 0x00, 0x00]
        XCTAssertThrowsError(try VESCProtocolParser.parseTelemetry(payload: tooShort))
    }

    func testTelemetryWrongCommandThrows() {
        var payload = [UInt8](repeating: 0, count: 54)
        payload[0] = 0x99 // wrong command
        XCTAssertThrowsError(try VESCProtocolParser.parseTelemetry(payload: payload))
    }

    // MARK: - Speed Calculation

    func testSpeedCalculation() {
        var s = DrivetrainSettings()
        s.motorPolePairs  = 7
        s.gearRatio       = 3.0
        s.wheelDiameterMM = 100.0

        // wheelCircumference = π × 0.1 m ≈ 0.3142 m
        // mechRPM = 10000/7 ≈ 1428.6 rpm
        // wheelRPM = 1428.6/3 ≈ 476.2 rpm
        // speed_ms = 476.2/60 × 0.3142 ≈ 2.494 m/s
        // speed_kmh ≈ 8.98 km/h

        let speed = s.speedKMH(erpm: 10000)
        XCTAssertEqual(speed, 8.98, accuracy: 0.1)
    }
}


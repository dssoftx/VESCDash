import Foundation
import Combine

/// Generates synthetic VESC telemetry packets for Xcode Previews and simulator testing.
/// Usage: attach an observer to `packetPublisher` and feed packets into your parser.
final class MockVESCSimulator {

    let packetPublisher = PassthroughSubject<[UInt8], Never>()

    private var timer: AnyCancellable?
    private var tick = 0

    func start() {
        timer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.emitPacket() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func emitPacket() {
        tick += 1

        var t = TelemetryData()
        let phase = Double(tick) * 0.1

        // Simulate an acceleration run then coast
        let erpm = Int32(max(0, sin(phase * 0.3) * 15000))
        t.rpm               = erpm
        t.inputVoltage      = Float(42.0 - Double(tick) * 0.001)  // slow voltage drop
        t.motorCurrent      = Float(abs(sin(phase)) * 35)
        t.batteryCurrent    = Float(abs(sin(phase)) * 28)
        t.dutyCycle         = Float(abs(sin(phase * 0.3)) * 0.8)
        t.mosfetTemperature = Float(25 + abs(sin(phase * 0.1)) * 40)
        t.motorTemperature  = Float(22 + abs(sin(phase * 0.08)) * 60)
        t.ampHours          = Float(Double(tick) * 0.001)
        t.wattHours         = Float(Double(tick) * 0.04)
        t.faultCode         = 0
        t.timestamp         = Date()

        // Encode as a real VESC packet so the full parser pipeline is exercised
        let payload = buildTelemetryPayload(from: t)
        let packet  = VESCProtocolParser.buildPacket(payload: payload)

        do {
            let decoded = try VESCProtocolParser.parsePacket(bytes: packet)
            packetPublisher.send(decoded)
        } catch {
            print("MockSimulator encode/decode roundtrip error: \(error)")
        }
    }

    // MARK: - Encode TelemetryData → COMM_GET_VALUES payload bytes

    func buildTelemetryPayload(from t: TelemetryData) -> [UInt8] {
        var buf = [UInt8]()
        buf.append(VESCCommand.getValues.rawValue)

        appendInt16(&buf, Int16(t.mosfetTemperature * 10))
        appendInt16(&buf, Int16(t.motorTemperature  * 10))
        appendInt32(&buf, Int32(t.motorCurrent      * 100))
        appendInt32(&buf, Int32(t.batteryCurrent    * 100))
        appendInt32(&buf, Int32(t.avgId             * 100))
        appendInt32(&buf, Int32(t.avgIq             * 100))
        appendInt16(&buf, Int16(t.dutyCycle         * 1000))
        appendInt32(&buf, t.rpm)
        appendInt16(&buf, Int16(t.inputVoltage      * 10))
        appendInt32(&buf, Int32(t.ampHours          * 10000))
        appendInt32(&buf, Int32(t.ampHoursCharged   * 10000))
        appendInt32(&buf, Int32(t.wattHours         * 10000))
        appendInt32(&buf, Int32(t.wattHoursCharged  * 10000))
        appendInt32(&buf, t.tachometer)
        appendInt32(&buf, t.tachometerAbs)
        buf.append(t.faultCode)

        return buf
    }

    private func appendInt16(_ buf: inout [UInt8], _ v: Int16) {
        let u = UInt16(bitPattern: v)
        buf.append(UInt8(u >> 8))
        buf.append(UInt8(u & 0xFF))
    }

    private func appendInt32(_ buf: inout [UInt8], _ v: Int32) {
        let u = UInt32(bitPattern: v)
        buf.append(UInt8(u >> 24))
        buf.append(UInt8((u >> 16) & 0xFF))
        buf.append(UInt8((u >> 8)  & 0xFF))
        buf.append(UInt8(u & 0xFF))
    }
}

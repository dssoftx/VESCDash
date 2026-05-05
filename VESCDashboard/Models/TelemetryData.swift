import Foundation

/// Parsed telemetry snapshot from VESC COMM_GET_VALUES response.
/// Temperatures in °C, currents in A, voltage in V.
struct TelemetryData: Equatable {
    var mosfetTemperature: Float = 0
    var motorTemperature: Float = 0
    var motorCurrent: Float = 0       // avg_motor_current
    var batteryCurrent: Float = 0     // avg_input_current
    var avgId: Float = 0              // d-axis current
    var avgIq: Float = 0              // q-axis current
    var dutyCycle: Float = 0          // -1.0 to 1.0
    var rpm: Int32 = 0                // electrical RPM from VESC
    var inputVoltage: Float = 0
    var ampHours: Float = 0
    var ampHoursCharged: Float = 0
    var wattHours: Float = 0
    var wattHoursCharged: Float = 0
    var tachometer: Int32 = 0
    var tachometerAbs: Int32 = 0
    var faultCode: UInt8 = 0
    var timestamp: Date = Date()

    static let empty = TelemetryData()

    var faultDescription: String {
        switch faultCode {
        case 0: return "No Fault"
        case 1: return "Over Voltage"
        case 2: return "Under Voltage"
        case 3: return "DRV Fault"
        case 4: return "ABS Over Current"
        case 5: return "Over Temp FET"
        case 6: return "Over Temp Motor"
        case 7: return "Gate Driver Over Voltage"
        case 8: return "Gate Driver Under Voltage 1"
        case 9: return "Gate Driver Under Voltage 2"
        case 10: return "MCU 5V Too Low"
        default: return "Fault \(faultCode)"
        }
    }

    var hasFault: Bool { faultCode != 0 }
}

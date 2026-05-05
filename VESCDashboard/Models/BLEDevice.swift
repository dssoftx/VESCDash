import Foundation
import CoreBluetooth

struct BLEDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int

    init(peripheral: CBPeripheral, rssi: Int) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        self.name = peripheral.name ?? "VESC \(peripheral.identifier.uuidString.prefix(8))"
        self.rssi = rssi
    }

    static func == (lhs: BLEDevice, rhs: BLEDevice) -> Bool {
        lhs.id == rhs.id
    }

    var signalStrengthIcon: String {
        switch rssi {
        case ..<(-90): return "wifi.slash"
        case -90 ..< -70: return "wifi.exclamationmark"
        case -70 ..< -50: return "wifi"
        default: return "wifi"
        }
    }
}

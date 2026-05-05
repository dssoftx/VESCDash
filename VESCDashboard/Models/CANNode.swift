import Foundation

struct CANNode: Identifiable, Hashable {
    let id: Int       // VESC CAN bus ID (0–253)
    var name: String
    var hwVersion: String?   // e.g. "6.05 · 75_300", populated after FW_VERSION read

    init(id: Int) {
        self.id = id
        self.name = "VESC #\(id)"
    }
}

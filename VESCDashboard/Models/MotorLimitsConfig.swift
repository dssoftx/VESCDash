import Foundation

struct MotorLimitsConfig: Codable, Equatable {
    /// Max battery (input) current drawn from pack (A, positive).
    var batteryCurrentMax: Float = 40.0
    /// Max regen current returned to pack (A, **negative**, e.g. -12).
    var batteryCurrentRegen: Float = -12.0
    /// Max motor phase current (A, positive).
    var phaseCurrentMax: Float = 60.0
    /// Absolute peak current before hard cutoff (A, positive).
    var absCurrentMax: Float = 130.0
}

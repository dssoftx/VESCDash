import Foundation

struct MotorLimitsConfig: Codable, Equatable {
    // Current limits
    var phaseCurrentMax: Float = 60.0
    var phaseCurrentRegen: Float = -60.0      // l_current_min (negative, phase braking)
    var batteryCurrentMax: Float = 40.0
    var batteryCurrentRegen: Float = -12.0    // l_in_current_min (negative)
    var absCurrentMax: Float = 130.0

    // FOC settings
    var zeroVectorFreqHz: Float = 30000.0     // foc_f_zv — switching freq
    var observerType: Int = 3                 // foc_observer_type (0–6, default=MXLemming λ)
    var fieldWeakeningCurrentMax: Float = 0.0 // foc_fw_current_max — 0 = disabled
    var fieldWeakeningDutyStart: Float = 0.9  // foc_fw_duty_start (0–1, duty where FW activates)
}

// MARK: - Motor Profile (runtime speed / power / current-scale limits)

struct MotorProfile: Codable, Equatable {
    var maxERPM: Float = 100_000        // l_max_erpm  — forward speed limit (positive)
    var minERPM: Float = -100_000       // l_min_erpm  — reverse speed limit (negative)
    var wattMax: Float = 1_500_000      // l_watt_max  — max discharge power (W); very high = disabled
    var wattMin: Float = -1_500_000     // l_watt_min  — max regen power (W, negative); very negative = disabled
    var currentMaxScale: Float = 1.0    // l_current_max_scale — accel current fraction (0–1)
    var currentMinScale: Float = 1.0    // l_current_min_scale — braking current fraction (0–1)
}

extension MotorLimitsConfig {
    static let observerNames = [
        "Ortega Original",
        "MXLemming",
        "Ortega + λ Comp",
        "MXLemming + λ Comp",
        "MXV",
        "MXV + λ Comp",
        "MXV + λ Comp (Linear)",
    ]
}

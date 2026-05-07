import Foundation

// MARK: - Battery Configuration

enum BatteryChem: String, CaseIterable, Codable {
    case liPo    = "LiPo"
    case liIon   = "Li-Ion"
    case liFePO4 = "LiFePO₄"

    var maxCellV: Float {
        switch self {
        case .liPo, .liIon: return 4.20
        case .liFePO4:      return 3.65
        }
    }
    var cutStartCellV: Float {
        switch self {
        case .liPo:   return 3.50
        case .liIon:  return 3.30
        case .liFePO4: return 3.00
        }
    }
    var cutEndCellV: Float {
        switch self {
        case .liPo:   return 3.20
        case .liIon:  return 3.00
        case .liFePO4: return 2.80
        }
    }
    var hint: String {
        switch self {
        case .liPo:   return "4.20 / 3.50 / 3.20 V per cell — high power density, common in RC."
        case .liIon:  return "4.20 / 3.30 / 3.00 V per cell — 18650/21700, good cycle life."
        case .liFePO4: return "3.65 / 3.00 / 2.80 V per cell — very safe, long life, lower energy."
        }
    }
}

struct BatteryConfig: Codable {
    var chemistry:  BatteryChem = .liIon
    var cellSeries: Int   = 10
    var capacityAh: Float = 5.0
    var maxCRating: Float = 30.0

    var maxVoltage:  Float { Float(cellSeries) * chemistry.maxCellV }
    var cutStartV:   Float { Float(cellSeries) * chemistry.cutStartCellV }
    var cutEndV:     Float { Float(cellSeries) * chemistry.cutEndCellV }
    var minVin:      Float { 8.0 }          // fixed hardware floor
    var maxVin:      Float { maxVoltage + 2.0 }  // headroom above full charge
    var maxCurrentA: Float { capacityAh * maxCRating }
}

// MARK: - Motor Limits

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

struct MotorProfile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "New Profile"
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

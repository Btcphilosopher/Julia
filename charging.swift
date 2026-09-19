import Foundation
import UIKit

// MARK: - Charging Observation

struct ChargingObservation {
    let batteryLevel: Double          // 0...1
    let batteryState: UIDevice.BatteryState
    let thermalState: ProcessInfo.ThermalState
    let lowPowerMode: Bool
    let elapsedSeconds: Double

    init() {
        let device = UIDevice.current
        let process = ProcessInfo.processInfo

        self.batteryLevel = max(0, min(1, Double(device.batteryLevel)))
        self.batteryState = device.batteryState
        self.thermalState = process.thermalState
        self.lowPowerMode = process.isLowPowerModeEnabled
        self.elapsedSeconds = 0
    }
}

// MARK: - Charging Mode

enum ChargingMode {
    case maximum
    case fast
    case balanced
    case thermalProtection
    case nearlyFull
}

// MARK: - Recommendation

struct ChargingRecommendation {
    let mode: ChargingMode

    /// Desired charge target in percentage.
    let targetSOC: Double

    /// Relative charging aggressiveness.
    /// 1.0 = maximum modelled aggressiveness.
    let aggressiveness: Double

    /// Whether the workload should be reduced.
    let reduceWorkload: Bool

    /// Whether the user should be warned about heat.
    let thermalWarning: Bool

    let reason: String
}

// MARK: - Fast Charging Engine

actor AureomFastChargeEngine {

    private var previousSOC: Double?
    private var previousTime: Date?

    private var estimatedChargeRate: Double = 0

    // MARK: Main update

    func update(
        batteryLevel: Double,
        thermalState: ProcessInfo.ThermalState,
        batteryState: UIDevice.BatteryState
    ) -> ChargingRecommendation {

        let now = Date()

        if let oldSOC = previousSOC,
           let oldTime = previousTime {

            let dt = now.timeIntervalSince(oldTime)

            if dt > 5 {

                let deltaSOC = batteryLevel - oldSOC

                // Fraction of battery per hour.
                let rate = deltaSOC / dt * 3600

                // Exponential smoothing.
                estimatedChargeRate =
                    estimatedChargeRate * 0.8 +
                    rate * 0.2
            }
        }

        previousSOC = batteryLevel
        previousTime = now

        return optimise(
            soc: batteryLevel,
            thermalState: thermalState,
            batteryState: batteryState
        )
    }

    // MARK: Optimiser

    private func optimise(
        soc: Double,
        thermalState: ProcessInfo.ThermalState,
        batteryState: UIDevice.BatteryState
    ) -> ChargingRecommendation {

        guard batteryState == .charging ||
              batteryState == .full else {

            return ChargingRecommendation(
                mode: .balanced,
                targetSOC: soc,
                aggressiveness: 0,
                reduceWorkload: false,
                thermalWarning: false,
                reason: "Device is not charging."
            )
        }

        // ------------------------------------------------
        // Thermal constraint
        // ------------------------------------------------

        switch thermalState {

        case .critical:

            return ChargingRecommendation(
                mode: .thermalProtection,
                targetSOC: min(soc + 0.05, 0.80),
                aggressiveness: 0.15,
                reduceWorkload: true,
                thermalWarning: true,
                reason: "Critical thermal state."
            )

        case .serious:

            return ChargingRecommendation(
                mode: .thermalProtection,
                targetSOC: min(soc + 0.10, 0.85),
                aggressiveness: 0.30,
                reduceWorkload: true,
                thermalWarning: true,
                reason: "High device temperature."
            )

        case .fair:

            return ChargingRecommendation(
                mode: .balanced,
                targetSOC: min(soc + 0.20, 0.90),
                aggressiveness: 0.60,
                reduceWorkload: true,
                thermalWarning: true,
                reason: "Moderate thermal load."
            )

        case .nominal:
            break

        @unknown default:
            break
        }

        // ------------------------------------------------
        // SOC optimisation
        // ------------------------------------------------

        if soc >= 0.95 {

            return ChargingRecommendation(
                mode: .nearlyFull,
                targetSOC: 1.0,
                aggressiveness: 0.35,
                reduceWorkload: false,
                thermalWarning: false,
                reason: "Near full charge; reduce charging stress."
            )
        }

        if soc < 0.30 {

            return ChargingRecommendation(
                mode: .maximum,
                targetSOC: 0.80,
                aggressiveness: 1.0,
                reduceWorkload: false,
                thermalWarning: false,
                reason: "Low battery; maximise charging opportunity."
            )
        }

        if soc < 0.80 {

            return ChargingRecommendation(
                mode: .fast,
                targetSOC: 0.90,
                aggressiveness: 0.85,
                reduceWorkload: false,
                thermalWarning: false,
                reason: "High-efficiency fast-charge region."
            )
        }

        return ChargingRecommendation(
            mode: .balanced,
            targetSOC: 1.0,
            aggressiveness: 0.55,
            reduceWorkload: false,
            thermalWarning: false,
            reason: "High SOC; prioritise thermal and ageing control."
        )
    }
}
The interesting part: make it predictive

Rather than simply saying:

"Battery is 40%, charge quickly."

you can build a controller around a simplified battery model:

$$ P_{battery}=P_{input}-P_{loss} $$

and

$$ P_{loss}=I^2R $$

with thermal dynamics:

$$ C_{th}\frac{dT}{dt} = P_{loss}-h(T-T_{ambient}) $$

Then optimise:

$$ J = w_1(\text{time to target}) + w_2(\text{temperature}) + w_3(\text{ageing}) + w_4(\text{energy loss}) $$

The algorithm searches possible charging strategies and chooses the one minimising J.

Where Julia becomes useful

I'd actually make Swift the real-time controller/model and Julia the calibration engine.

Julia can run thousands/millions of simulated charging cycles:

function charging_cost(
    soc,
    temperature,
    current,
    resistance,
    target_soc
)

    joule_heat = current^2 * resistance

    thermal_penalty =
        max(temperature - 35.0, 0.0)^2

    ageing_penalty =
        current^1.7 *
        (1.0 + thermal_penalty / 20.0)

    time_penalty =
        max(target_soc - soc, 0.0) /
        max(current, 0.01)

    return (
        1.0 * time_penalty +
        0.5 * joule_heat +
        2.0 * thermal_penalty +
        1.5 * ageing_penalty
    )
end

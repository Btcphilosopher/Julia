import Foundation

struct BatteryObservation: Sendable {

    let stateOfCharge: Double       // 0...1
    let voltage: Double             // volts
    let current: Double             // amps
    let temperatureC: Double
    let externalPowerW: Double
}

struct BatteryState: Sendable {

    var stateOfCharge: Double
    var temperatureC: Double

    var internalResistanceOhm: Double
    var efficiency: Double

    var electricalPowerW: Double
    var heatLossW: Double
    var ageingStress: Double
}

struct BatteryRecommendation: Sendable {

    let targetPowerW: Double
    let predictedHeatW: Double
    let predictedEfficiency: Double
    let thermalStress: Double
    let score: Double
}

actor AureomBatteryEngine {

    private var state =
        BatteryState(
            stateOfCharge: 0.50,
            temperatureC: 22.0,
            internalResistanceOhm: 0.08,
            efficiency: 0.95,
            electricalPowerW: 0,
            heatLossW: 0,
            ageingStress: 0
        )

    // Simplified thermal model.
    private let thermalMass =
        180.0       // effective J/K

    private let coolingCoefficient =
        0.45        // W/K

    func update(
        observation: BatteryObservation,
        elapsedSeconds: Double
    ) -> BatteryState {

        let current =
            observation.current

        let resistance =
            state.internalResistanceOhm

        // Joule heating:
        //
        // P = I²R
        //
        let heat =
            current *
            current *
            resistance

        let cooling =
            coolingCoefficient *
            (
                observation.temperatureC -
                22.0
            )

        let netHeat =
            heat -
            cooling

        let deltaTemperature =
            netHeat *
            elapsedSeconds /
            thermalMass

        let temperature =
            observation.temperatureC +
            deltaTemperature

        let electricalPower =
            abs(
                observation.voltage *
                observation.current
            )

        let usefulPower =
            max(
                electricalPower -
                heat,
                0
            )

        let efficiency =
            electricalPower > 0
                ? usefulPower /
                  electricalPower
                : 1.0

        let thermalStress =
            thermalStressScore(
                temperature:
                    temperature
            )

        let ageing =
            ageingScore(
                soc:
                    observation.stateOfCharge,
                temperature:
                    temperature,
                current:
                    abs(current)
            )

        state =
            BatteryState(
                stateOfCharge:
                    observation.stateOfCharge,
                temperatureC:
                    temperature,
                internalResistanceOhm:
                    resistance,
                efficiency:
                    efficiency,
                electricalPowerW:
                    electricalPower,
                heatLossW:
                    heat,
                ageingStress:
                    ageing
            )

        return state
    }

    func optimise(
        state:
            BatteryState
    ) -> BatteryRecommendation {

        var best:
            BatteryRecommendation?

        // Candidate operating power.
        for power in stride(
            from: 1.0,
            through: 30.0,
            by: 0.5
        ) {

            let predictedHeat =
                estimateHeat(
                    power:
                        power,
                    resistance:
                        state.internalResistanceOhm,
                    voltage:
                        4.0
                )

            let efficiency =
                max(
                    0,
                    1.0 -
                    predictedHeat /
                    power
                )

            let thermal =
                thermalStressScore(
                    temperature:
                        state.temperatureC +
                        predictedHeat * 0.25
                )

            let score =
                  efficiency * 0.45
                + (1.0 - thermal) * 0.35
                + (1.0 - state.ageingStress) * 0.20

            let candidate =
                BatteryRecommendation(
                    targetPowerW:
                        power,
                    predictedHeatW:
                        predictedHeat,
                    predictedEfficiency:
                        efficiency,
                    thermalStress:
                        thermal,
                    score:
                        score
                )

            if best == nil ||
                candidate.score >
                best!.score {

                best = candidate
            }
        }

        return best!
    }

    private func estimateHeat(
        power: Double,
        resistance: Double,
        voltage: Double
    ) -> Double {

        let current =
            power /
            voltage

        return current *
               current *
               resistance
    }

    private func thermalStressScore(
        temperature: Double
    ) -> Double {

        if temperature <= 25 {
            return 0.0
        }

        if temperature >= 45 {
            return 1.0
        }

        return (
            temperature -
            25
        ) / 20
    }

    private func ageingScore(
        soc: Double,
        temperature: Double,
        current: Double
    ) -> Double {

        let highSOC =
            max(
                0,
                (soc - 0.80) /
                0.20
            )

        let temperatureStress =
            thermalStressScore(
                temperature:
                    temperature
            )

        let currentStress =
            min(
                current / 10.0,
                1.0
            )

        return min(
            1.0,
            0.35 * highSOC +
            0.45 * temperatureStress +
            0.20 * currentStress
        )
    }
}


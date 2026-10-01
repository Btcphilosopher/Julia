using LinearAlgebra

# ============================================================
# Vauxhall / RR Engine Fuel Injection Simulator
#
# Research / simulation model
# ============================================================

struct EngineConfig
    cylinders::Int
    displacement::Float64
    compression_ratio::Float64

    injector_flow::Float64
    injector_dead_time::Float64

    stoich_afr::Float64

    max_rpm::Float64
    idle_rpm::Float64

    fuel_energy::Float64
    volumetric_efficiency::Float64
end


struct EngineState
    rpm::Float64
    throttle::Float64

    manifold_pressure::Float64
    intake_temperature::Float64
    coolant_temperature::Float64

    lambda::Float64
    air_mass_flow::Float64

    engine_torque::Float64
    fuel_flow::Float64
end


struct InjectorCommand
    pulse_width::Float64
    fuel_mass::Float64
    lambda_target::Float64
end


# ============================================================
# Air model
# ============================================================

function estimate_air_mass(
    cfg::EngineConfig,
    state::EngineState
)

    R_air = 287.05

    pressure =
        state.manifold_pressure * 1000.0

    temperature =
        state.intake_temperature + 273.15

    density =
        pressure /
        (R_air * temperature)

    # Four-stroke engine:
    # one intake event every two crank revolutions.

    cycles_per_second =
        state.rpm / 120.0

    theoretical_volume =
        cfg.displacement *
        cycles_per_second

    air_mass =
        density *
        theoretical_volume *
        cfg.volumetric_efficiency

    return max(air_mass, 0.0)
end


# ============================================================
# Target lambda
# ============================================================

function target_lambda(
    state::EngineState
)

    rpm = state.rpm
    throttle = state.throttle

    # Light load:
    # economical stoichiometric operation.

    if throttle < 0.35

        return 1.0

    # Medium load:
    # slightly enriched.

    elseif throttle < 0.75

        return 0.97

    # High load:
    # richer simulated calibration.

    else

        return 0.88

    end
end


# ============================================================
# Required fuel mass
# ============================================================

function required_fuel_mass(
    cfg::EngineConfig,
    air_mass,
    lambda_target
)

    afr =
        cfg.stoich_afr *
        lambda_target

    return air_mass / afr
end


# ============================================================
# Injector model
# ============================================================

function injector_command(
    cfg::EngineConfig,
    state::EngineState
)

    air_mass =
        estimate_air_mass(
            cfg,
            state
        )

    λ =
        target_lambda(state)

    fuel_mass =
        required_fuel_mass(
            cfg,
            air_mass,
            λ
        )

    # Total fuel flow → per-cylinder flow.

    cylinder_fuel =
        fuel_mass /
        cfg.cylinders

    # Injector flow is represented here as
    # kg/s.

    pulse_width =
        cylinder_fuel /
        cfg.injector_flow

    pulse_width +=
        cfg.injector_dead_time

    return InjectorCommand(
        pulse_width,
        cylinder_fuel,
        λ
    )
end


# ============================================================
# Combustion efficiency
# ============================================================

function combustion_efficiency(
    lambda
)

    # Simplified efficiency curve.

    if lambda < 0.80

        return 0.78

    elseif lambda < 0.90

        return 0.92

    elseif lambda < 1.05

        return 0.98

    elseif lambda < 1.20

        return 0.94

    else

        return 0.80
    end
end


# ============================================================
# Engine torque model
# ============================================================

function engine_torque(
    cfg::EngineConfig,
    state::EngineState,
    command::InjectorCommand
)

    efficiency =
        combustion_efficiency(
            command.lambda_target
        )

    # Approximate fuel energy released per second.

    power =
        command.fuel_mass *
        cfg.fuel_energy *
        efficiency

    rpm_factor =
        1.0 -
        0.35 *
        (state.rpm / cfg.max_rpm)^2

    throttle_factor =
        0.25 +
        0.75 *
        state.throttle

    power *=
        rpm_factor *
        throttle_factor

    ω =
        max(
            state.rpm *
            2π / 60.0,
            1.0
        )

    torque =
        power / ω

    return max(torque, 0.0)
end

Now we can create the virtual engine.

# ============================================================
# Example high-performance RR simulation engine
# ============================================================

cfg = EngineConfig(

    8,              # cylinders
    4.0,            # 4.0 litre displacement
    10.5,           # compression ratio

    0.000035,       # injector flow kg/s
    0.0008,         # injector dead time

    14.7,           # stoichiometric AFR

    7500.0,         # maximum RPM
    750.0,          # idle RPM

    44e6,           # fuel energy J/kg

    0.90            # volumetric efficiency
)


state = EngineState(

    2500.0,         # RPM
    0.55,           # throttle

    75.0,           # MAP kPa
    30.0,            # intake temperature
    90.0,            # coolant temperature

    1.0,            # lambda

    0.0,
    0.0,
    0.0
)


injector =
    injector_command(
        cfg,
        state
    )


torque =
    engine_torque(
        cfg,
        state,
        injector
    )


println("Injector pulse width: ",
        injector.pulse_width * 1000,
        " ms")

println("Fuel per cycle: ",
        injector.fuel_mass * 1000,
        " g")

println("Lambda target: ",
        injector.lambda_target)

println("Estimated torque: ",
        torque,
        " Nm")
Then make the injection genuinely intelligent

The next level is a cylinder-by-cylinder fuel controller:

                ENGINE
                  │
       ┌──────────┼──────────┐
       ▼          ▼          ▼
     CYL 1      CYL 2      CYL 3 ...
       │          │          │
   lambda 1   lambda 2   lambda 3
       │          │          │
       └──────────┼──────────┘
                  ▼
             ECU MODEL
                  │
        ┌─────────┼─────────┐
        ▼         ▼         ▼
     AFR error  Temp      RPM/load
        │         │         │
        └─────────┼─────────┘
                  ▼
          FUEL CORRECTION
                  │
                  ▼
          INJECTOR PULSE

For example:

function lambda_correction(
    measured_lambda,
    target_lambda
)

    error =
        target_lambda -
        measured_lambda

    correction =
        1.0 + 0.20 * error

    return clamp(
        correction,
        0.80,
        1.20
    )
end

Then:

function closed_loop_injection(
    base_fuel,
    measured_lambda,
    target_lambda
)

    correction =
        lambda_correction(
            measured_lambda,
            target_lambda
        )

    return base_fuel * correction
end
The full Aureom-style version

I'd ultimately make this another module alongside your steering, suspension, braking and weight-distribution systems:

                    VEHICLE AI
                       │
 ┌─────────────────────┼──────────────────────┐
 │                     │                      │
 ▼                     ▼                      ▼
WEIGHT             DRIVER                    ROAD
MODEL              MODEL                     MODEL
 │                     │                      │
 └──────────────┬──────┴───────────┬─────────┘
                ▼                  ▼
             ENGINE              CHASSIS
                │                  │
       ┌────────┼───────┐    ┌─────┼─────┐
       ▼        ▼       ▼    ▼     ▼     ▼
     AIR      FUEL    IGNITION STEER BRAKE SUSPENSION
       │        │       │
       └────────┼───────┘
                ▼
           COMBUSTION
                │
                ▼
           TORQUE MODEL
                │
                ▼
          TRANSMISSION
                │
                ▼
             WHEELS

And the fuel optimiser's objective can become:

J =
    100.0 * abs(lambda - lambda_target)^2 +
     30.0 * fuel_consumption^2 +
     20.0 * torque_error^2 +
     10.0 * injector_variation^2 +
     10.0 * temperature_error^2

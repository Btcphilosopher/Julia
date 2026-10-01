Julia regenerative-braking optimiser
using Printf

# ============================================================
# SMART REGENERATIVE BRAKING OPTIMISER
#
# Consumer EV research / simulation model
#
# Objective:
#   Maximise recovered battery energy during long,
#   gentle deceleration while respecting:
#
#   - battery SOC
#   - battery temperature
#   - battery charge-power limit
#   - motor speed
#   - motor torque
#   - vehicle stability
#   - requested deceleration
#   - low-speed regeneration limits
# ============================================================


struct RegenConfig

    # Vehicle
    mass::Float64
    wheel_radius::Float64
    final_drive::Float64

    # Motor
    max_regen_torque::Float64
    max_regen_power::Float64
    motor_efficiency::Float64

    # Battery
    battery_capacity_kwh::Float64
    max_charge_power_kw::Float64

    # Operating limits
    minimum_regen_speed::Float64
    full_regen_speed::Float64

    maximum_soc::Float64
    minimum_battery_temperature::Float64
    maximum_battery_temperature::Float64

    # Control
    control_period::Float64
end


struct VehicleState

    speed::Float64

    acceleration::Float64

    brake_request::Float64

    accelerator_position::Float64

    battery_soc::Float64
    battery_temperature::Float64

    motor_speed::Float64
end


struct RegenCommand

    regen_torque::Float64
    regen_power::Float64

    friction_brake_force::Float64

    recovered_power::Float64

    regen_fraction::Float64
end


# ============================================================
# Motor speed
# ============================================================

function calculate_motor_speed(
    cfg::RegenConfig,
    vehicle_speed
)

    wheel_speed =
        vehicle_speed /
        cfg.wheel_radius

    return wheel_speed *
           cfg.final_drive
end


# ============================================================
# Speed-dependent regen availability
# ============================================================

function speed_factor(
    cfg::RegenConfig,
    speed
)

    v1 =
        cfg.minimum_regen_speed

    v2 =
        cfg.full_regen_speed

    if speed <= v1
        return 0.0

    elseif speed >= v2
        return 1.0

    else
        return (
            speed - v1
        ) / (
            v2 - v1
        )
    end
end


# ============================================================
# Battery SOC availability
# ============================================================

function soc_factor(
    cfg::RegenConfig,
    soc
)

    # Leave a buffer near maximum SOC.

    if soc >= cfg.maximum_soc
        return 0.0

    elseif soc >= 0.90

        return (
            cfg.maximum_soc - soc
        ) / (
            cfg.maximum_soc - 0.90
        )

    else
        return 1.0
    end
end


# ============================================================
# Battery temperature availability
# ============================================================

function temperature_factor(
    cfg::RegenConfig,
    temperature
)

    Tmin =
        cfg.minimum_battery_temperature

    Tmax =
        cfg.maximum_battery_temperature

    if temperature <= Tmin
        return 0.25

    elseif temperature >= Tmax
        return 0.25

    elseif temperature < 15.0

        return clamp(
            (temperature - Tmin) /
            (15.0 - Tmin),
            0.25,
            1.0
        )

    elseif temperature > 40.0

        return clamp(
            (Tmax - temperature) /
            (Tmax - 40.0),
            0.25,
            1.0
        )

    else
        return 1.0
    end
end


# ============================================================
# Battery charging power limit
# ============================================================

function battery_power_limit(
    cfg::RegenConfig,
    state::VehicleState
)

    soc_limit =
        soc_factor(
            cfg,
            state.battery_soc
        )

    temperature_limit =
        temperature_factor(
            cfg,
            state.battery_temperature
        )

    return cfg.max_charge_power_kw *
           1000.0 *
           soc_limit *
           temperature_limit
end


# ============================================================
# Motor power limit
# ============================================================

function motor_power_limit(
    cfg::RegenConfig,
    motor_speed
)

    # Simplified motor operating limit.

    return cfg.max_regen_power
end


# ============================================================
# Maximum regenerative torque
# ============================================================

function maximum_regen_torque(
    cfg::RegenConfig,
    state::VehicleState
)

    speed =
        max(state.speed, 0.1)

    ω =
        calculate_motor_speed(
            cfg,
            speed
        )

    motor_power =
        motor_power_limit(
            cfg,
            ω
        )

    battery_power =
        battery_power_limit(
            cfg,
            state
        )

    available_power =
        min(
            motor_power,
            battery_power
        )

    power_torque_limit =
        available_power /
        max(ω, 1.0)

    speed_limit =
        speed_factor(
            cfg,
            state.speed
        )

    return min(
        cfg.max_regen_torque,
        power_torque_limit
    ) * speed_limit
end


# ============================================================
# Requested braking force
# ============================================================

function requested_braking_force(
    cfg::RegenConfig,
    state::VehicleState
)

    # brake_request = 0 → no braking
    # brake_request = 1 → strong braking

    maximum_deceleration =
        8.0

    requested_deceleration =
        state.brake_request *
        maximum_deceleration

    return (
        cfg.mass *
        requested_deceleration
    )
end


# ============================================================
# Convert wheel force to motor torque
# ============================================================

function force_to_motor_torque(
    cfg::RegenConfig,
    force
)

    return (
        force *
        cfg.wheel_radius /
        cfg.final_drive
    )
end


# ============================================================
# REGEN OPTIMISER
# ============================================================

function optimise_regen(
    cfg::RegenConfig,
    state::VehicleState
)

    requested_force =
        requested_braking_force(
            cfg,
            state
        )

    requested_torque =
        force_to_motor_torque(
            cfg,
            requested_force
        )

    available_torque =
        maximum_regen_torque(
            cfg,
            state
        )

    # Priority is regeneration.

    regen_torque =
        min(
            requested_torque,
            available_torque
        )

    # Convert regen torque to wheel braking force.

    regen_force =
        regen_torque *
        cfg.final_drive /
        cfg.wheel_radius

    # Anything regeneration cannot supply
    # goes to friction braking.

    friction_force =
        max(
            requested_force -
            regen_force,
            0.0
        )

    # Mechanical wheel power.

    wheel_power =
        regen_force *
        state.speed

    recovered_power =
        wheel_power *
        cfg.motor_efficiency

    regen_fraction =
        if requested_force > 0
            regen_force /
            requested_force
        else
            0.0
        end

    return RegenCommand(
        regen_torque,
        recovered_power,
        friction_force,
        recovered_power,
        regen_fraction
    )
end
Example consumer EV
cfg = RegenConfig(

    1900.0,       # mass kg
    0.33,         # wheel radius m
    9.0,          # final drive

    450.0,        # max regen torque Nm
    120_000.0,    # max regen power W
    0.90,         # motor efficiency

    82.0,         # battery kWh
    120.0,        # maximum charge power kW

    3.0,          # regen starts fading below this speed
    12.0,         # full regen above this speed

    0.98,         # maximum operating SOC
    0.0,          # minimum temperature
    50.0,         # maximum temperature

    0.01
)


state = VehicleState(

    27.8,         # 100 km/h

    -1.0,         # current acceleration

    0.20,         # gentle braking

    0.0,          # accelerator

    0.62,         # 62% SOC

    25.0,         # battery temperature

    0.0
)


command =
    optimise_regen(
        cfg,
        state
    )


@printf(
    "Regenerative torque: %.1f Nm\n",
    command.regen_torque
)

@printf(
    "Recovered power: %.1f kW\n",
    command.recovered_power / 1000
)

@printf(
    "Friction brake force: %.1f N\n",
    command.friction_brake_force
)

@printf(
    "Regenerative fraction: %.1f %%\n",
    command.regen_fraction * 100
)
The important part: optimise a long burn

For your idea, I wouldn't optimise each instant independently.

I'd make Julia look ahead over the next 5–20 seconds.

For example:

100 km/h
   │
   │ driver lifts accelerator
   ▼
 95 km/h ───────────────┐
                        │
 90 km/h ───────────────┤
                        │
 85 km/h ───────────────┤
                        │
 80 km/h ───────────────┤
                        │
 75 km/h ───────────────┤
                        │
 70 km/h ───────────────┤
                        │
 65 km/h ───────────────┤
                        ▼
                 battery receives
                 controlled power

Instead of maximising instantaneous regenerative torque, define:

J =
    - recovered_energy +
      1000.0 * braking_error^2 +
      500.0 * jerk^2 +
      100.0 * battery_stress^2

Then Julia chooses a gentle, sustained regeneration profile.

This matters because regenerative braking is fundamentally a power-management problem as well as a braking problem. The available kinetic energy falls with the square of speed, while battery charging power is constrained; TRL's analysis specifically describes why a power-limited system may need progressively changing regenerative torque during a deceleration.

Predictive controller
function regen_objective(
    recovered_energy,
    braking_error,
    jerk,
    battery_stress
)

    return (
        -recovered_energy +
        1000.0 * braking_error^2 +
        500.0 * jerk^2 +
        100.0 * battery_stress^2
    )
end

Then you can run candidate regeneration levels:

function choose_regen_level(
    cfg,
    state
)

    candidates =
        range(
            0.0,
            1.0,
            length = 21
        )

    best_level = 0.0
    best_cost = Inf

    for level in candidates

        requested =
            requested_braking_force(
                cfg,
                state
            )

        available =
            maximum_regen_torque(
                cfg,
                state
            )

        torque =
            level *
            available

        regen_force =
            torque *
            cfg.final_drive /
            cfg.wheel_radius

        braking_error =
            max(
                requested -
                regen_force,
                0.0
            )

        recovered_energy =
            regen_force *
            state.speed *
            cfg.motor_efficiency

        battery_stress =
            recovered_energy /
            max(
                battery_power_limit(
                    cfg,
                    state
                ),
                1.0
            )

        cost =
            regen_objective(
                recovered_energy,
                braking_error,
                0.0,
                battery_stress
            )

        if cost < best_cost

            best_cost = cost
            best_level = level

        end
    end

    return best_level
end

That gives you an adaptive regeneration controller rather than a fixed "regen level 1/2/3".

And I'd connect it to the other Julia systems
                 VEHICLE AI
                     │
          ┌──────────┴──────────┐
          │                     │
    Weight Distribution     Road Prediction
          │                     │
          └──────────┬──────────┘
                     ▼
             REGEN OPTIMISER
                     │
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
 Battery SOC     Motor state    Vehicle state
       │             │             │
       └─────────────┼─────────────┘
                     ▼
              BRAKE BLENDING
                /         \
               /           \
          REGEN MOTOR     FRICTION
               \           /
                \         /
                 ▼       ▼
                  VEHICLE

So on a long gentle slowdown, it might choose something like:

Requested deceleration     -0.35 m/s²

Regenerative braking       -0.31 m/s²
Friction braking           -0.04 m/s²

Motor recovery              28.4 kW
Battery acceptance          31.0 kW

Battery SOC                  61.8%
Battery temperature          26°C

Regeneration                89%


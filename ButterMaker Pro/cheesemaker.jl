module NorthbridgeOS

using Printf

@enum Phase begin
    IDLE
    HEATING
    HOLDING
    ADD_COAGULANT
    SETTING
    CUT_CURD
    READY_TO_DRAIN
    COMPLETE
    FAULT
end

"""
Control-test configuration, not a validated cheesemaking recipe.
"""
Base.@kwdef struct Recipe
    target_c::Float64 = 32.0
    hold_s::Float64 = 30.0
    set_s::Float64 = 60.0
    heat_timeout_s::Float64 = 900.0
end

Base.@kwdef struct Limits
    software_trip_c::Float64 = 45.0
    max_sample_age_s::Float64 = 1.0
    max_tick_s::Float64 = 0.5
    max_sensor_disagreement_c::Float64 = 3.0
end

struct Inputs
    temperature_c::Float64
    guard_temperature_c::Float64
    sampled_at::Float64
    bowl_present::Bool
    lid_closed::Bool
    liquid_present::Bool
    thermal_cutout_ok::Bool
    motor_ok::Bool
    leak_detected::Bool
end

struct Outputs
    heater::Float64
    stirrer::Float64
end

const OFF = Outputs(0.0, 0.0)

mutable struct PIController
    kp::Float64
    ki::Float64
    integral::Float64
end

function regulate!(p::PIController, error::Float64, dt::Float64)
    candidate = clamp(p.integral + error * dt, -100.0, 100.0)
    raw = p.kp * error + p.ki * candidate
    command = clamp(raw, 0.0, 1.0)

    # Conditional integration prevents wind-up at output limits.
    if 0.0 <= raw <= 1.0 ||
       (raw > 1.0 && error < 0.0) ||
       (raw < 0.0 && error > 0.0)
        p.integral = candidate
    end

    return command
end

mutable struct Kernel
    phase::Phase
    recipe::Recipe
    limits::Limits
    controller::PIController
    outputs::Outputs
    last_tick::Float64
    phase_started::Float64
    qualified_hold_s::Float64
    fault::Union{Nothing,String}
    events::Vector{String}
end

function Kernel(recipe=Recipe(), limits=Limits())
    values = (
        recipe.target_c, recipe.hold_s,
        recipe.set_s, recipe.heat_timeout_s,
        limits.software_trip_c,
    )
    all(isfinite, values) || error("Non-finite configuration")
    0 < recipe.target_c < limits.software_trip_c ||
        error("Target must be below software trip temperature")
    recipe.hold_s > 0 && recipe.set_s > 0 ||
        error("Durations must be positive")
    recipe.heat_timeout_s > 0 || error("Invalid heat timeout")

    Kernel(
        IDLE, recipe, limits,
        PIController(0.18, 0.008, 0.0),
        OFF, NaN, 0.0, 0.0, nothing, String[],
    )
end

function transition!(k::Kernel, next::Phase, now::Float64)
    push!(k.events, @sprintf("%.2f: %s → %s", now, k.phase, next))
    k.phase = next
    k.phase_started = now
    k.controller.integral = 0.0
    k.outputs = OFF
end

function trip!(k::Kernel, reason::String, now::Float64)
    if k.phase != FAULT
        k.fault = reason
        push!(k.events, @sprintf("%.2f: FAULT: %s", now, reason))
        transition!(k, FAULT, now)
    end
    k.outputs = OFF
    return OFF
end

function input_fault(k::Kernel, x::Inputs, now::Float64)
    temperatures = (x.temperature_c, x.guard_temperature_c)

    all(isfinite, temperatures) || return "Invalid temperature sensor"
    isfinite(x.sampled_at) || return "Invalid sensor timestamp"

    age = now - x.sampled_at
    0 <= age <= k.limits.max_sample_age_s ||
        return "Stale or future-dated sensor sample"

    all(t -> -10.0 <= t <= 130.0, temperatures) ||
        return "Temperature outside sensor plausibility range"

    abs(x.temperature_c - x.guard_temperature_c) <=
        k.limits.max_sensor_disagreement_c ||
        return "Temperature sensors disagree"

    maximum(temperatures) < k.limits.software_trip_c ||
        return "Software overtemperature trip"

    x.thermal_cutout_ok || return "Hardware thermal cut-out open"
    !x.leak_detected || return "Leak detected"

    return nothing
end

"""
One deterministic scheduler tick.

Commands:
:start, :confirm_coagulant, :confirm_cut,
:confirm_drained, :abort, or :none.

A fault is latched. Recovery requires inspection and a fresh kernel;
the controller never resumes a food batch automatically.
"""
function tick!(
    k::Kernel,
    x::Inputs,
    now::Float64;
    command::Symbol=:none,
)
    isfinite(now) || return trip!(k, "Invalid clock", 0.0)
    k.phase == FAULT && return OFF

    dt = isnan(k.last_tick) ? 0.0 : now - k.last_tick

    if !isnan(k.last_tick) &&
       !(0.0 < dt <= k.limits.max_tick_s)
        return trip!(k, "Scheduler timing failure", now)
    end
    k.last_tick = now

    reason = input_fault(k, x, now)
    reason === nothing || return trip!(k, reason, now)

    command == :abort && return trip!(k, "Operator aborted batch", now)

    # Manual draining is allowed only after powered processing ends.
    powered_phase = k.phase in (
        HEATING, HOLDING, ADD_COAGULANT, SETTING, CUT_CURD,
    )

    if powered_phase && !(x.bowl_present && x.liquid_present)
        return trip!(k, "Bowl or liquid interlock lost", now)
    end

    # This concept requires a closed lid throughout active processing.
    if k.phase in (HEATING, HOLDING, SETTING) && !x.lid_closed
        return trip!(k, "Lid opened during active processing", now)
    end

    heater = 0.0
    stirrer = 0.0

    if k.phase == IDLE
        if command == :start
            if !(x.bowl_present && x.lid_closed && x.liquid_present)
                return trip!(k, "Start interlocks not satisfied", now)
            end
            transition!(k, HEATING, now)
        end

    elseif k.phase == HEATING
        if now - k.phase_started > k.recipe.heat_timeout_s
            return trip!(k, "Heating timeout", now)
        end

        x.motor_ok || return trip!(k, "Stirrer fault", now)

        heater = regulate!(
            k.controller, k.recipe.target_c - x.temperature_c, dt
        )
        stirrer = 0.20

        if abs(x.temperature_c - k.recipe.target_c) <= 0.3
            k.qualified_hold_s = 0.0
            transition!(k, HOLDING, now)
        end

    elseif k.phase == HOLDING
        if now - k.phase_started > k.recipe.hold_s + 120.0
            return trip!(k, "Unable to maintain hold temperature", now)
        end

        x.motor_ok || return trip!(k, "Stirrer fault", now)

        heater = regulate!(
            k.controller, k.recipe.target_c - x.temperature_c, dt
        )
        stirrer = 0.20

        if abs(x.temperature_c - k.recipe.target_c) <= 0.5
            k.qualified_hold_s += dt
        else
            k.qualified_hold_s = 0.0
        end

        if k.qualified_hold_s >= k.recipe.hold_s
            transition!(k, ADD_COAGULANT, now)
        end

    elseif k.phase == ADD_COAGULANT
        # Heater and motor remain off while the user handles ingredients.
        if command == :confirm_coagulant && x.lid_closed
            transition!(k, SETTING, now)
        end

    elseif k.phase == SETTING
        # Unheated setting stage for this demonstration profile.
        # Do not stir the forming curd.
        if now - k.phase_started >= k.recipe.set_s
            transition!(k, CUT_CURD, now)
        end

    elseif k.phase == CUT_CURD
        if command == :confirm_cut
            transition!(k, READY_TO_DRAIN, now)
        end

    elseif k.phase == READY_TO_DRAIN
        # Basket lifting, draining and pressing are manual.
        if command == :confirm_drained
            transition!(k, COMPLETE, now)
        end
    end

    # Transitions into manual/end states immediately remove power.
    if k.phase in (HEATING, HOLDING)
        k.outputs = Outputs(clamp(heater, 0, 1), clamp(stirrer, 0, 1))
    else
        k.outputs = OFF
    end

    return k.outputs
end

# ── Simulated hardware ──────────────────────────────────────────────

mutable struct SimPlant
    temperature_c::Float64
    ambient_c::Float64
end

function advance!(p::SimPlant, output::Outputs, dt::Float64)
    heating = 0.22 * output.heater
    heat_loss = 0.002 * (p.temperature_c - p.ambient_c)
    p.temperature_c += (heating - heat_loss) * dt
end

function sample(p::SimPlant, now::Float64)
    Inputs(
        p.temperature_c, p.temperature_c, now,
        true, true, true, true, true, false,
    )
end

function demo()
    kernel = Kernel()
    plant = SimPlant(20.0, 20.0)
    dt = 0.25

    try
        for step in 0:8000
            now = step * dt

            # Automatic acknowledgements are for simulation ONLY.
            command =
                kernel.phase == IDLE ? :start :
                kernel.phase == ADD_COAGULANT ? :confirm_coagulant :
                kernel.phase == CUT_CURD ? :confirm_cut :
                kernel.phase == READY_TO_DRAIN ? :confirm_drained :
                :none

            output = tick!(kernel, sample(plant, now), now;
                           command=command)

            advance!(plant, output, dt)

            kernel.phase in (COMPLETE, FAULT) && break
        end
    finally
        kernel.outputs = OFF
    end

    foreach(println, kernel.events)
    println("Final state: ", kernel.phase)
    println("Fault: ", something(kernel.fault, "none"))
    return kernel
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    NorthbridgeOS.demo()
end


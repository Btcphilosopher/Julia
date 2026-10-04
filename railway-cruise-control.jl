# ============================================================
# हिंदी रेलवे क्रूज़ नियंत्रण
# ============================================================

struct रेलगाड़ी
    द्रव्यमान::Float64
    अधिकतम_कर्षण::Float64
    अधिकतम_ब्रेक::Float64
end

रेलगाड़ी_१ = रेलगाड़ी(
    450_000.0,
    300_000.0,
    400_000.0
)

mutable struct नियंत्रक_स्थिति
    समाकलन::Float64
    पिछली_त्रुटि::Float64
end

function क्रूज़_नियंत्रण!(
    नियंत्रक_स्थिति,
    लक्ष्य_गति,
    वास्तविक_गति,
    समय_चरण
)

    त्रुटि =
        लक्ष्य_गति - वास्तविक_गति

    नियंत्रक_स्थिति.समाकलन +=
        त्रुटि * समय_चरण

    व्युत्पन्न =
        (त्रुटि -
         नियंत्रक_स्थिति.पिछली_त्रुटि) /
         समय_चरण

    नियंत्रक_स्थिति.पिछली_त्रुटि =
        त्रुटि

    नियंत्रण_बल =
        80_000.0 * त्रुटि +
        8_000.0 *
        नियंत्रक_स्थिति.समाकलन +
        20_000.0 * व्युत्पन्न

    return नियंत्रण_बल
end








# ============================================================
# HINDI RAILWAY CRUISE CONTROL
# Julia prototype for automatic train speed regulation
# ============================================================

using Printf

# ------------------------------------------------------------
# Train parameters
# ------------------------------------------------------------

struct Train
    mass::Float64              # kg
    max_tractive_force::Float64 # N
    max_brake_force::Float64    # N
    rolling_resistance::Float64 # N
    drag_coefficient::Float64
    frontal_area::Float64       # m²
end

# Example electric multiple-unit / locomotive train
train = Train(
    450_000.0,     # 450 tonnes
    300_000.0,     # maximum traction
    400_000.0,     # maximum braking
    4_000.0,
    0.9,
    12.0
)

# ------------------------------------------------------------
# Cruise-control parameters
# ------------------------------------------------------------

struct CruiseController
    kp::Float64
    ki::Float64
    kd::Float64

    integral_limit::Float64

    traction_limit::Float64
    brake_limit::Float64
end

controller = CruiseController(
    80_000.0,       # proportional gain
    8_000.0,        # integral gain
    20_000.0,       # derivative gain
    100.0,
    300_000.0,
    400_000.0
)

# ------------------------------------------------------------
# Railway operating modes
# ------------------------------------------------------------

@enum CruiseMode begin
    MANUAL
    CRUISE
    SPEED_LIMIT
    EMERGENCY
end

# ------------------------------------------------------------
# Environmental model
# ------------------------------------------------------------

struct RailwayEnvironment
    gradient::Float64       # decimal gradient (+ = uphill)
    wind_speed::Float64     # m/s
    air_density::Float64
end

# ------------------------------------------------------------
# Calculate aerodynamic drag
# ------------------------------------------------------------

function aerodynamic_drag(train, speed, wind_speed, air_density)

    relative_air_speed = speed + wind_speed

    return 0.5 *
           air_density *
           train.drag_coefficient *
           train.frontal_area *
           relative_air_speed^2
end

# ------------------------------------------------------------
# Calculate total resistance
# ------------------------------------------------------------

function railway_resistance(train, speed, environment)

    aerodynamic =
        aerodynamic_drag(
            train,
            speed,
            environment.wind_speed,
            environment.air_density
        )

    rolling = train.rolling_resistance

    gradient_force =
        train.mass *
        9.81 *
        environment.gradient

    return rolling + aerodynamic + gradient_force
end

# ------------------------------------------------------------
# PID cruise controller
# ------------------------------------------------------------

mutable struct ControllerState
    integral::Float64
    previous_error::Float64
end

state = ControllerState(0.0, 0.0)

function cruise_control!(
    controller,
    state,
    target_speed,
    actual_speed,
    dt
)

    error = target_speed - actual_speed

    # Integral term
    state.integral += error * dt

    state.integral =
        clamp(
            state.integral,
            -controller.integral_limit,
            controller.integral_limit
        )

    # Derivative term
    derivative =
        (error - state.previous_error) / dt

    state.previous_error = error

    # PID output
    output =
        controller.kp * error +
        controller.ki * state.integral +
        controller.kd * derivative

    # Positive = traction
    # Negative = braking

    if output >= 0

        traction = clamp(
            output,
            0.0,
            controller.traction_limit
        )

        brake = 0.0

    else

        traction = 0.0

        brake = clamp(
            -output,
            0.0,
            controller.brake_limit
        )
    end

    return traction, brake
end

# ------------------------------------------------------------
# Train dynamics
# ------------------------------------------------------------

function train_acceleration(
    train,
    speed,
    traction,
    brake,
    environment
)

    resistance =
        railway_resistance(
            train,
            speed,
            environment
        )

    net_force =
        traction -
        brake -
        resistance

    return net_force / train.mass
end

# ------------------------------------------------------------
# Railway cruise simulation
# ------------------------------------------------------------

function simulate_cruise(
    train,
    controller,
    target_speed;
    duration = 180.0,
    dt = 0.1,
    environment =
        RailwayEnvironment(
            0.0,
            0.0,
            1.225
        )
)

    state = ControllerState(
        0.0,
        0.0
    )

    time = Float64[]
    speed = Float64[]
    traction = Float64[]
    braking = Float64[]
    distance = Float64[]

    v = 0.0
    x = 0.0

    for t in 0:dt:duration

        traction_force,
        brake_force =
            cruise_control!(
                controller,
                state,
                target_speed,
                v,
                dt
            )

        acceleration =
            train_acceleration(
                train,
                v,
                traction_force,
                brake_force,
                environment
            )

        # Integrate train dynamics
        v = max(
            0.0,
            v + acceleration * dt
        )

        x += v * dt

        push!(time, t)
        push!(speed, v)
        push!(traction, traction_force)
        push!(braking, brake_force)
        push!(distance, x)
    end

    return (
        time = time,
        speed = speed,
        traction = traction,
        braking = braking,
        distance = distance
    )
end

# ------------------------------------------------------------
# Example: 110 km/h cruise
# ------------------------------------------------------------

target_speed =
    110.0 / 3.6       # km/h → m/s

result =
    simulate_cruise(
        train,
        controller,
        target_speed
    )

# ------------------------------------------------------------
# Report
# ------------------------------------------------------------

println("============================================")
println(" HINDI RAILWAY CRUISE CONTROL")
println("============================================")

@printf(
    "Target speed: %.1f km/h\n",
    target_speed * 3.6
)

@printf(
    "Final speed:  %.1f km/h\n",
    result.speed[end] * 3.6
)

@printf(
    "Distance:     %.2f km\n",
    result.distance[end] / 1000
)

println("============================================")

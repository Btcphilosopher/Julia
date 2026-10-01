using Printf

# ============================================================
# INSTANT START MANAGER
# Julia automotive start-up simulation
#
# Research / simulation prototype
# ============================================================

@enum StartState begin
    SLEEP
    READY
    BUTTON_TAPPED
    AUTHENTICATING
    SYSTEMS_READY
    CRANKING
    COMBUSTION
    RUNNING
    FAILED
end


struct StartConfig
    ecu_wake_time::Float64
    key_auth_time::Float64
    fuel_prime_time::Float64
    sensor_sync_time::Float64
    starter_response_time::Float64

    crank_rpm_threshold::Float64
    target_idle_rpm::Float64

    dt::Float64
end


mutable struct StartSystem

    state::StartState

    timer::Float64

    key_authorised::Bool
    ecu_awake::Bool
    fuel_ready::Bool
    sensors_ready::Bool
    ignition_ready::Bool

    rpm::Float64
    engine_running::Bool

    total_latency::Float64
end


# ============================================================
# Create system
# ============================================================

function create_start_system()

    StartSystem(
        SLEEP,
        0.0,

        false,
        false,
        false,
        false,
        false,

        0.0,
        false,

        0.0
    )
end


# ============================================================
# PRE-ARMING
# ============================================================

function prearm!(system::StartSystem)

    # Vehicle has detected the driver / key
    # and prepares the powertrain.

    system.ecu_awake = true
    system.key_authorised = true
    system.fuel_ready = true
    system.sensors_ready = true
    system.ignition_ready = true

    system.state = READY
end


# ============================================================
# BUTTON EVENT
# ============================================================

function button_tap!(system::StartSystem)

    if system.state == READY

        system.state = BUTTON_TAPPED
        system.timer = 0.0

    end
end


# ============================================================
# START CONTROLLER
# ============================================================

function update!(
    system::StartSystem,
    cfg::StartConfig
)

    dt = cfg.dt

    system.timer += dt

    # --------------------------------------------------------
    # Button has been pressed
    # --------------------------------------------------------

    if system.state == BUTTON_TAPPED

        system.state =
            AUTHENTICATING

        system.timer = 0.0

    end


    # --------------------------------------------------------
    # Authentication
    # --------------------------------------------------------

    if system.state == AUTHENTICATING

        if system.key_authorised

            system.state =
                SYSTEMS_READY

            system.timer = 0.0

        elseif system.timer >
               cfg.key_auth_time

            system.state =
                FAILED
        end
    end


    # --------------------------------------------------------
    # Systems already prepared
    # --------------------------------------------------------

    if system.state == SYSTEMS_READY

        if system.ecu_awake &&
           system.fuel_ready &&
           system.sensors_ready &&
           system.ignition_ready

            system.state =
                CRANKING

            system.timer = 0.0
        end
    end


    # --------------------------------------------------------
    # Starter
    # --------------------------------------------------------

    if system.state == CRANKING

        # Simulated starter acceleration.

        system.rpm +=
            2200.0 * dt

        if system.rpm >=
           cfg.crank_rpm_threshold

            system.state =
                COMBUSTION

            system.timer = 0.0
        end
    end


    # --------------------------------------------------------
    # Combustion catches
    # --------------------------------------------------------

    if system.state == COMBUSTION

        # Simplified combustion acceleration.

        system.rpm +=
            4000.0 * dt

        if system.rpm >=
           cfg.target_idle_rpm

            system.rpm =
                cfg.target_idle_rpm

            system.engine_running =
                true

            system.state =
                RUNNING

            system.total_latency +=
                system.timer
        end
    end


    return system.state
end
Simulate a tap
cfg = StartConfig(

    0.020,     # ECU wake
    0.015,     # authentication
    0.050,     # fuel prime
    0.010,     # sensor sync
    0.020,     # starter response

    250.0,     # crank RPM threshold
    750.0,     # idle RPM

    0.001      # 1 ms simulation
)


car = create_start_system()

# ------------------------------------------------------------
# The vehicle has already been pre-armed.
# ------------------------------------------------------------

prearm!(car)

println("Vehicle state: ", car.state)

# Driver taps START.

button_tap!(car)

start_time = nothing
running_time = nothing

for t in 0.0:cfg.dt:2.0

    if start_time === nothing &&
       car.state == BUTTON_TAPPED

        start_time = t
    end

    update!(car, cfg)

    if car.state == RUNNING

        running_time = t
        break
    end
end


@printf(
    "Engine running after %.3f seconds\n",
    running_time
)
But I'd improve this considerably

The clever part is predictive wake-up.

Instead of:

tap → wake ECU → authenticate → prime → synchronise → crank

you want:

driver approaching
       ↓
vehicle wakes
       ↓
authenticate
       ↓
ECU ready
       ↓
fuel system ready
       ↓
sensors synchronised
       ↓
driver sits down
       ↓
BUTTON TAP
       ↓
CRANK IMMEDIATELY

Bosch's passive-start architecture already illustrates this general principle: vehicle/key presence can be established before the start-button event, so the button press can become the final start request rather than the beginning of the entire preparation sequence.

Julia predictive wake model
struct WakePrediction

    driver_distance::Float64
    approach_speed::Float64

    predicted_entry_time::Float64

    key_probability::Float64
    start_probability::Float64
end


function predict_driver_arrival(
    distance,
    approach_speed
)

    time =
        distance /
        max(approach_speed, 0.1)

    return time
end


function should_prearm(
    prediction::WakePrediction
)

    return (
        prediction.key_probability > 0.80 &&
        prediction.start_probability > 0.60 &&
        prediction.predicted_entry_time < 30.0
    )
end

That gives you a vehicle start prediction system.

For example:

Driver 8 m away
       ↓
UWB/BLE detected
       ↓
P(driver enters) = 0.94
       ↓
P(driver starts car) = 0.87
       ↓
PRE-ARM
       ↓
ECU + sensors + fuel + ignition ready
       ↓
BUTTON
       ↓
START
One more important optimisation

I'd make the ECU continuously maintain a START READINESS SCORE:

function readiness_score(system)

    score = 0.0

    score += system.ecu_awake       ? 0.20 : 0.0
    score += system.key_authorised  ? 0.20 : 0.0
    score += system.fuel_ready      ? 0.20 : 0.0
    score += system.sensors_ready   ? 0.20 : 0.0
    score += system.ignition_ready  ? 0.20 : 0.0

    return score
end

So the dashboard/vehicle computer effectively knows:

START READINESS

ECU              ██████████ 100%
KEY              ██████████ 100%
FUEL             ██████████ 100%
SENSORS          ██████████ 100%
IGNITION         ██████████ 100%

SYSTEM READY     100%

BUTTON → ENGINE


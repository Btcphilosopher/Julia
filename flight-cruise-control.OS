Architecture
                    ┌───────────────────────┐
                    │     FLIGHT PLAN       │
                    │ waypoints / altitude  │
                    │ speed / constraints   │
                    └───────────┬───────────┘
                                │
                    ┌───────────▼───────────┐
                    │     PYTHON / R         │
                    │ simulation + analysis  │
                    └───────────┬───────────┘
                                │
              ┌─────────────────▼─────────────────┐
              │            JULIA                  │
              │ dynamics / estimation / tuning    │
              │ Monte-Carlo / optimisation        │
              └─────────────────┬─────────────────┘
                                │
                       simulated state
                                │
              ┌─────────────────▼─────────────────┐
              │              RUST                 │
              │ deterministic supervisory logic  │
              │ mode management / health         │
              └─────────────────┬─────────────────┘
                                │
                       validated commands
                                │
              ┌─────────────────▼─────────────────┐
              │                C                  │
              │ real-time simulation interface   │
              │ fixed-rate control-loop model    │
              └──────────────────────────────────┘

The key principle is that C/Rust don't get to invent flight behaviour: they're the deterministic execution/supervisory side of the simulator, while Python/Julia are where we experiment with models and optimisation.

1. Python — mission simulator
# ============================================================
# LONG HAUL FLIGHT SIMULATOR
# Research / simulation only
# ============================================================

from dataclasses import dataclass
import math
import random

DT = 1.0


@dataclass
class AircraftState:
    latitude: float
    longitude: float

    altitude_m: float
    airspeed_ms: float

    heading_deg: float
    vertical_speed_ms: float

    fuel_kg: float

    pitch_deg: float
    roll_deg: float

    simulation_time: float = 0.0


@dataclass
class FlightPlan:
    waypoints: list
    cruise_altitude_m: float
    cruise_speed_ms: float


@dataclass
class GuidanceCommand:
    target_altitude_m: float
    target_speed_ms: float
    target_heading_deg: float


def wrap_heading(angle):

    return angle % 360.0


def heading_error(target, current):

    error = target - current

    while error > 180:
        error -= 360

    while error < -180:
        error += 360

    return error


def distance_nm(a, b):

    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)

    dlat = lat2 - lat1
    dlon = lon2 - lon1

    x = dlon * math.cos(
        (lat1 + lat2) / 2
    )

    y = dlat

    return (
        math.sqrt(x*x + y*y)
        * 3440.065
    )


def desired_heading(current, target):

    lat1, lon1 = map(
        math.radians,
        current
    )

    lat2, lon2 = map(
        math.radians,
        target
    )

    dlon = lon2 - lon1

    y = math.sin(dlon) * math.cos(lat2)

    x = (
        math.cos(lat1) *
        math.sin(lat2)
        -
        math.sin(lat1) *
        math.cos(lat2) *
        math.cos(dlon)
    )

    return math.degrees(
        math.atan2(y, x)
    ) % 360


def guidance(
    state,
    plan,
    waypoint_index
):

    target = plan.waypoints[
        waypoint_index
    ]

    heading = desired_heading(
        (
            state.latitude,
            state.longitude
        ),
        target
    )

    return GuidanceCommand(
        plan.cruise_altitude_m,
        plan.cruise_speed_ms,
        heading
    )


def update_aircraft(
    state,
    command
):

    # --------------------------------------------------------
    # Simple response model.
    # This is NOT an aircraft flight-control law.
    # --------------------------------------------------------

    speed_error = (
        command.target_speed_ms -
        state.airspeed_ms
    )

    state.airspeed_ms += (
        0.015 *
        speed_error
    )

    altitude_error = (
        command.target_altitude_m -
        state.altitude_m
    )

    state.vertical_speed_ms = max(
        -5.0,
        min(
            5.0,
            altitude_error * 0.01
        )
    )

    state.altitude_m += (
        state.vertical_speed_ms *
        DT
    )

    hdg_error = heading_error(
        command.target_heading_deg,
        state.heading_deg
    )

    state.heading_deg += (
        max(
            -2.0,
            min(
                2.0,
                hdg_error * 0.05
            )
        )
    )

    state.heading_deg = wrap_heading(
        state.heading_deg
    )

    # --------------------------------------------------------
    # Navigation propagation
    # --------------------------------------------------------

    distance_m = (
        state.airspeed_ms *
        DT
    )

    heading_rad = math.radians(
        state.heading_deg
    )

    state.latitude += (
        distance_m *
        math.cos(heading_rad)
        / 111_320.0
    )

    cos_lat = max(
        0.1,
        math.cos(
            math.radians(
                state.latitude
            )
        )
    )

    state.longitude += (
        distance_m *
        math.sin(heading_rad)
        /
        (
            111_320.0 *
            cos_lat
        )
    )

    # --------------------------------------------------------
    # Simple fuel model
    # --------------------------------------------------------

    fuel_burn_rate = (
        0.00020 *
        state.airspeed_ms
    )

    state.fuel_kg -= (
        fuel_burn_rate *
        DT
    )

    state.simulation_time += DT


def run_flight():

    state = AircraftState(
        latitude=51.47,
        longitude=-0.45,
        altitude_m=10000,
        airspeed_ms=230,
        heading_deg=90,
        vertical_speed_ms=0,
        fuel_kg=120000,
        pitch_deg=0,
        roll_deg=0
    )

    plan = FlightPlan(
        waypoints=[
            (51.0, 5.0),
            (50.0, 15.0),
            (48.0, 30.0),
            (45.0, 45.0)
        ],
        cruise_altitude_m=11000,
        cruise_speed_ms=235
    )

    waypoint = 0

    telemetry = []

    for _ in range(
        6 * 60 * 60
    ):

        if waypoint >= len(
            plan.waypoints
        ):
            break

        command = guidance(
            state,
            plan,
            waypoint
        )

        update_aircraft(
            state,
            command
        )

        target = plan.waypoints[
            waypoint
        ]

        distance = distance_nm(
            (
                state.latitude,
                state.longitude
            ),
            target
        )

        if distance < 40:
            waypoint += 1

        telemetry.append({
            "time": state.simulation_time,
            "lat": state.latitude,
            "lon": state.longitude,
            "altitude": state.altitude_m,
            "speed": state.airspeed_ms,
            "heading": state.heading_deg,
            "fuel": state.fuel_kg,
            "waypoint": waypoint
        })

    return telemetry


if __name__ == "__main__":

    telemetry = run_flight()

    print(
        f"Simulation samples: "
        f"{len(telemetry)}"
    )

    if telemetry:

        final = telemetry[-1]

        print(
            f"Final altitude: "
            f"{final['altitude']:.1f} m"
        )

        print(
            f"Final speed: "
            f"{final['speed']:.1f} m/s"
        )

        print(
            f"Fuel remaining: "
            f"{final['fuel']:.1f} kg"
        )
2. Julia — aircraft dynamics + optimisation

Julia is where I'd make the simulation substantially more sophisticated: differential equations, atmospheric models, fuel optimisation and Monte-Carlo analysis.

# ============================================================
# CRUISELAB.jl
# Aircraft cruise simulation / optimisation
# ============================================================

module CruiseLab

using Statistics
using Random

export Aircraft, CruiseState,
       drag, fuel_flow,
       step!, simulate,
       optimise_cruise

struct Aircraft

    mass_kg::Float64
    wing_area_m2::Float64
    cd0::Float64
    induced_drag_factor::Float64

    max_thrust_N::Float64

    fuel_capacity_kg::Float64
end


mutable struct CruiseState

    altitude_m::Float64
    velocity_ms::Float64

    mass_kg::Float64

    fuel_kg::Float64

    distance_m::Float64
end


function air_density(
    altitude
)

    ρ0 = 1.225

    scale_height = 8500.0

    return (
        ρ0 *
        exp(
            -altitude /
            scale_height
        )
    )
end


function dynamic_pressure(
    aircraft,
    state
)

    ρ =
        air_density(
            state.altitude_m
        )

    return (
        0.5 *
        ρ *
        state.velocity_ms^2
    )
end


function lift_coefficient(
    aircraft,
    state
)

    q =
        dynamic_pressure(
            aircraft,
            state
        )

    return (
        state.mass_kg *
        9.81
        /
        (
            q *
            aircraft.wing_area_m2
        )
    )
end


function drag(
    aircraft,
    state
)

    cl =
        lift_coefficient(
            aircraft,
            state
        )

    cd =
        aircraft.cd0 +
        aircraft.induced_drag_factor *
        cl^2

    q =
        dynamic_pressure(
            aircraft,
            state
        )

    return (
        q *
        aircraft.wing_area_m2 *
        cd
    )
end


function fuel_flow(
    aircraft,
    state
)

    thrust =
        drag(
            aircraft,
            state
        )

    # Simplified propulsion model

    tsfc =
        0.000015

    return (
        thrust *
        tsfc
    )
end


function step!(
    aircraft,
    state,
    dt
)

    drag_force =
        drag(
            aircraft,
            state
        )

    thrust =
        min(
            aircraft.max_thrust_N,
            drag_force
        )

    acceleration =
        (
            thrust -
            drag_force
        ) /
        state.mass_kg

    state.velocity_ms +=
        acceleration *
        dt

    burn =
        fuel_flow(
            aircraft,
            state
        ) *
        dt

    state.fuel_kg =
        max(
            0.0,
            state.fuel_kg -
            burn
        )

    state.mass_kg =
        max(
            1.0,
            state.mass_kg -
            burn
        )

    state.distance_m +=
        state.velocity_ms *
        dt

    return state
end


function simulate(
    aircraft,
    initial_state;
    duration_s=3600.0,
    dt=1.0
)

    state =
        deepcopy(
            initial_state
        )

    history =
        CruiseState[]

    steps =
        Int(
            duration_s / dt
        )

    for _ in 1:steps

        step!(
            aircraft,
            state,
            dt
        )

        push!(
            history,
            deepcopy(state)
        )

        if state.fuel_kg <= 0
            break
        end
    end

    return history
end


function cruise_score(
    aircraft,
    altitude,
    speed,
    fuel
)

    state =
        CruiseState(
            altitude,
            speed,
            aircraft.mass_kg,
            fuel,
            0.0
        )

    history =
        simulate(
            aircraft,
            state;
            duration_s=3600
        )

    isempty(history) &&
        return -Inf

    final =
        history[end]

    return (
        final.distance_m /
        max(
            aircraft.mass_kg -
            final.mass_kg,
            1.0
        )
    )
end


function optimise_cruise(
    aircraft,
    altitudes,
    speeds
)

    best_score = -Inf
    best = nothing

    for altitude in altitudes

        for speed in speeds

            score =
                cruise_score(
                    aircraft,
                    altitude,
                    speed,
                    aircraft.fuel_capacity_kg
                )

            if score > best_score

                best_score = score

                best = (
                    altitude=altitude,
                    speed=speed,
                    score=score
                )
            end
        end
    end

    return best
end


end

Then a Julia runner:

using .CruiseLab

aircraft =
    Aircraft(
        180_000.0,
        360.0,
        0.020,
        0.045,
        240_000.0,
        100_000.0
    )

state =
    CruiseState(
        11_000.0,
        235.0,
        aircraft.mass_kg,
        aircraft.fuel_capacity_kg,
        0.0
    )

history =
    simulate(
        aircraft,
        state;
        duration_s=6*3600
    )

best =
    optimise_cruise(
        aircraft,
        9_000.0:500.0:13_000.0,
        190.0:5.0:250.0
    )

println("Optimised cruise:")
println(best)

println(
    "Distance = ",
    history[end].distance_m / 1000,
    " km"
)

println(
    "Fuel remaining = ",
    history[end].fuel_kg,
    " kg"
)
3. Rust — deterministic supervisory state machine

This is where I'd put mode/state management, not experimental control-law development.

// ============================================================
// CRUISE SUPERVISOR
// Simulation / research implementation
// ============================================================

#[derive(Debug, Clone, Copy, PartialEq)]
enum Mode {
    Manual,
    Cruise,
    Degraded,
    Disengaged,
}

#[derive(Debug, Clone, Copy)]
struct AircraftState {
    altitude_m: f64,
    airspeed_ms: f64,
    heading_deg: f64,

    radio_altitude_valid: bool,
    air_data_valid: bool,
    navigation_valid: bool,

    excessive_deviation: bool,
}

#[derive(Debug)]
struct Supervisor {
    mode: Mode,
    engagement_requested: bool,
}


impl Supervisor {

    fn new() -> Self {

        Self {
            mode: Mode::Manual,
            engagement_requested: false,
        }
    }


    fn disengage(&mut self) {

        self.mode =
            Mode::Disengaged;

        self.engagement_requested =
            false;
    }


    fn update(
        &mut self,
        state: AircraftState
    ) {

        // ----------------------------------------------------
        // Conservative supervisory behaviour.
        // ----------------------------------------------------

        if !state.air_data_valid ||
           !state.navigation_valid {

            self.mode =
                Mode::Degraded;

            return;
        }


        if state.excessive_deviation {

            self.mode =
                Mode::Degraded;

            return;
        }


        if self.engagement_requested {

            self.mode =
                Mode::Cruise;
        }
        else {

            self.mode =
                Mode::Manual;
        }
    }
}


fn main() {

    let mut supervisor =
        Supervisor::new();


    let state =
        AircraftState {

            altitude_m: 11000.0,

            airspeed_ms: 230.0,

            heading_deg: 90.0,

            radio_altitude_valid: true,

            air_data_valid: true,

            navigation_valid: true,

            excessive_deviation: false,
        };


    supervisor.engagement_requested =
        true;


    supervisor.update(
        state
    );


    println!(
        "Supervisor mode: {:?}",
        supervisor.mode
    );
}
4. C — fixed-rate simulation interface

For the C side, I'd keep it deliberately small and deterministic:

/*
 * ============================================================
 * CRUISE CORE
 *
 * Deterministic simulation interface.
 *
 * Research / SIL environment only.
 * ============================================================
 */

#include <stdint.h>
#include <stdio.h>

typedef struct {

    double altitude_m;
    double airspeed_ms;
    double heading_deg;

    double vertical_speed_ms;
    double fuel_kg;

} AircraftState;


typedef struct {

    double target_altitude_m;
    double target_speed_ms;
    double target_heading_deg;

} GuidanceCommand;


static double clamp(
    double value,
    double minimum,
    double maximum
)
{
    if (value < minimum)
        return minimum;

    if (value > maximum)
        return maximum;

    return value;
}


static double heading_error(
    double target,
    double current
)
{
    double error =
        target -
        current;

    while (error > 180.0)
        error -= 360.0;

    while (error < -180.0)
        error += 360.0;

    return error;
}


void simulation_step(
    AircraftState *state,
    const GuidanceCommand *command,
    double dt
)
{
    double altitude_error =
        command->target_altitude_m -
        state->altitude_m;


    double speed_error =
        command->target_speed_ms -
        state->airspeed_ms;


    double heading_error_value =
        heading_error(
            command->target_heading_deg,
            state->heading_deg
        );


    state->vertical_speed_ms =
        clamp(
            altitude_error * 0.01,
            -5.0,
            5.0
        );


    state->altitude_m +=
        state->vertical_speed_ms *
        dt;


    state->airspeed_ms +=
        clamp(
            speed_error * 0.01,
            -1.0,
            1.0
        );


    state->heading_deg +=
        clamp(
            heading_error_value * 0.05,
            -1.0,
            1.0
        );


    if (state->heading_deg >= 360.0)
        state->heading_deg -= 360.0;

    if (state->heading_deg < 0.0)
        state->heading_deg += 360.0;


    /*
     * Simplified simulation fuel model.
     */

    state->fuel_kg -=
        0.05 *
        state->airspeed_ms *
        dt;


    if (state->fuel_kg < 0.0)
        state->fuel_kg = 0.0;
}


int main(void)
{
    AircraftState aircraft = {

        .altitude_m = 11000.0,

        .airspeed_ms = 230.0,

        .heading_deg = 90.0,

        .vertical_speed_ms = 0.0,

        .fuel_kg = 100000.0
    };


    GuidanceCommand command = {

        .target_altitude_m = 11000.0,

        .target_speed_ms = 235.0,

        .target_heading_deg = 95.0
    };


    for (
        uint32_t i = 0;
        i < 3600;
        ++i
    ) {

        simulation_step(
            &aircraft,
            &command,
            1.0
        );
    }


    printf(
        "Altitude: %.2f m\n",
        aircraft.altitude_m
    );

    printf(
        "Speed: %.2f m/s\n",
        aircraft.airspeed_ms
    );

    printf(
        "Heading: %.2f deg\n",
        aircraft.heading_deg
    );

    printf(
        "Fuel: %.2f kg\n",
        aircraft.fuel_kg
    );


    return 0;
}
5. R — flight-data analytics

R can sit outside the real-time loop and analyse thousands of simulated flights:

# ============================================================
# FLIGHT ANALYTICS
# ============================================================

simulate_flight <- function(
    duration_hours = 10,
    cruise_speed = 230,
    fuel_initial = 100000
) {

    n <- duration_hours * 60

    time <- seq(
        0,
        duration_hours,
        length.out = n
    )

    speed <- rnorm(
        n,
        cruise_speed,
        1.5
    )

    altitude <- rnorm(
        n,
        11000,
        30
    )

    fuel_burn <- cumsum(
        abs(speed) * 0.05
    )

    fuel <- pmax(
        0,
        fuel_initial - fuel_burn
    )

    data.frame(
        time = time,
        speed = speed,
        altitude = altitude,
        fuel = fuel
    )
}


flights <- lapply(
    1:1000,
    function(i)
        simulate_flight(
            duration_hours = 10
        )
)


mean_final_fuel <- mean(
    sapply(
        flights,
        function(x)
            tail(x$fuel, 1)
    )
)


altitude_variability <- mean(
    sapply(
        flights,
        function(x)
            sd(x$altitude)
    )
)


cat(
    "Mean final fuel:",
    mean_final_fuel,
    "\n"
)


cat(
    "Mean altitude variability:",
    altitude_variability,
    "m\n"
)
The full system I'd ultimately build
                     LONG-HAUL FLIGHT DIGITAL TWIN
                                  │
       ┌──────────────────────────┼──────────────────────────┐
       │                          │                          │
       ▼                          ▼                          ▼
   AIRCRAFT MODEL             ATMOSPHERE                MISSION
       │                          │                          │
       ├── aerodynamics           ├── wind                   ├── route
       ├── mass                   ├── temperature            ├── waypoints
       ├── engines                ├── turbulence              ├── altitude
       ├── fuel                   └── pressure                └── speed
       │
       ▼
   STATE ESTIMATION
       │
       ├── air data
       ├── inertial state
       ├── navigation
       └── sensor health
       │
       ▼
   GUIDANCE / SUPERVISION
       │
       ├── cruise
       ├── altitude management
       ├── speed management
       ├── navigation
       └── mode management
       │
       ▼
   SIMULATED AIRCRAFT
       │
       ├── 1 Hz telemetry
       ├── fault injection
       ├── sensor degradation
       └── environmental disturbances
       │
       ├──────────────────────┐
       ▼                      ▼
    PYTHON                  JULIA
    scenarios              optimisation
    ML experiments         dynamics
    visualisation          Monte Carlo
       │                      │
       └──────────┬───────────┘
                  ▼
                  R
             STATISTICS
             fleet analysis
             reliability
             performance

The important engineering feature is the separation between experimentation and the deterministic core. For an actual certified aircraft, you'd need much more than "working code": requirements traceability, verification, validation, hardware/software assurance, failure analysis, deterministic timing, sensor redundancy, human-factor evaluation, hardware-in-the-loop and certification evidence. FAA guidance explicitly covers airborne software assurance and recognizes DO-178C and associated supplements; EASA's large-aircraft guidance also emphasizes evaluating the integrated aerodynamic closed loop and foreseeable flight-control behaviour.

So this gives you a substantial long-haul autopilot digital-twin/SIL foundation, without pretending that a few thousand lines of general-purpose code constitute flight-certified autopilot software.

###############################################################################
# LIFT OPTIMISATION / ELEVATOR DISPATCH ENGINE
# Julia
#
# Concept:
#   Building -> Floors -> Lifts -> Passenger Calls
#
# The dispatcher continuously evaluates every lift against every outstanding
# request and assigns the lowest-cost feasible lift.
###############################################################################

using LinearAlgebra
using Random

###############################################################################
# DATA STRUCTURES
###############################################################################

@enum Direction IDLE UP DOWN

mutable struct Lift
    id::Int
    floor::Int
    direction::Direction
    capacity::Int
    passengers::Int
    target_floors::Vector{Int}
    door_open::Bool
end

mutable struct Call
    id::Int
    floor::Int
    destination::Int
    timestamp::Float64
    passengers::Int
    priority::Float64
end

struct DispatchDecision
    lift_id::Int
    call_id::Int
    cost::Float64
end

###############################################################################
# PARAMETERS
###############################################################################

const FLOOR_HEIGHT = 3.5          # metres
const LIFT_SPEED = 2.5            # m/s
const DOOR_TIME = 3.0             # seconds
const FLOOR_STOP_TIME = 2.0       # seconds
const MAX_WAIT_PENALTY = 1000.0

###############################################################################
# BASIC PHYSICS
###############################################################################

function travel_time(from_floor::Int, to_floor::Int)

    floors = abs(to_floor - from_floor)

    if floors == 0
        return 0.0
    end

    distance = floors * FLOOR_HEIGHT

    return distance / LIFT_SPEED
end

###############################################################################
# DIRECTION
###############################################################################

function direction_to(lift::Lift, floor::Int)

    if floor > lift.floor
        return UP
    elseif floor < lift.floor
        return DOWN
    else
        return IDLE
    end

end

###############################################################################
# CAN LIFT SERVE REQUEST?
###############################################################################

function feasible(lift::Lift, call::Call)

    # Capacity constraint
    if lift.passengers + call.passengers > lift.capacity
        return false
    end

    # If lift is travelling UP, normally prefer calls above it.
    if lift.direction == UP
        if call.floor < lift.floor &&
           call.destination < call.floor

            return false
        end
    end

    # If lift is travelling DOWN
    if lift.direction == DOWN
        if call.floor > lift.floor &&
           call.destination > call.floor

            return false
        end
    end

    return true
end

###############################################################################
# NUMBER OF INTERMEDIATE STOPS
###############################################################################

function intermediate_stops(lift::Lift, call::Call)

    stops = 0

    for floor in lift.target_floors

        if lift.direction == UP &&
           floor >= lift.floor &&
           floor <= call.floor

            stops += 1

        elseif lift.direction == DOWN &&
               floor <= lift.floor &&
               floor >= call.floor

            stops += 1
        end

    end

    return stops
end

###############################################################################
# DIRECTION COMPATIBILITY
###############################################################################

function direction_penalty(lift::Lift, call::Call)

    desired = direction_to(lift, call.floor)

    if lift.direction == IDLE
        return 0.0
    end

    if lift.direction == desired
        return 0.0
    end

    # Changing direction is expensive
    return 20.0
end

###############################################################################
# LOAD PENALTY
###############################################################################

function load_penalty(lift::Lift)

    utilisation = lift.passengers / lift.capacity

    return utilisation^2 * 25.0
end

###############################################################################
# CONGESTION PENALTY
###############################################################################

function congestion_penalty(lift::Lift)

    return length(lift.target_floors) * 4.0
end

###############################################################################
# ESTIMATE ARRIVAL TIME
###############################################################################

function estimated_arrival(lift::Lift, call::Call)

    base = travel_time(lift.floor, call.floor)

    stops = intermediate_stops(lift, call)

    stop_time = stops * (DOOR_TIME + FLOOR_STOP_TIME)

    return base + stop_time
end

###############################################################################
# WAITING TIME PRIORITY
###############################################################################

function waiting_penalty(call::Call, current_time::Float64)

    waiting = current_time - call.timestamp

    # Increasing nonlinear penalty prevents starvation.
    return min(
        MAX_WAIT_PENALTY,
        waiting^2 * 0.15
    )
end

###############################################################################
# COMPLETE COST FUNCTION
###############################################################################

function dispatch_cost(
    lift::Lift,
    call::Call,
    current_time::Float64
)

    if !feasible(lift, call)
        return Inf
    end

    arrival = estimated_arrival(lift, call)

    direction = direction_penalty(lift, call)

    load = load_penalty(lift)

    congestion = congestion_penalty(lift)

    waiting = waiting_penalty(call, current_time)

    # Priority reduces effective cost
    priority_bonus = call.priority * 50.0

    cost =
        arrival * 10.0 +
        direction +
        load +
        congestion +
        waiting -
        priority_bonus

    return cost
end

###############################################################################
# OPTIMAL LIFT FOR ONE CALL
###############################################################################

function best_lift(
    lifts::Vector{Lift},
    call::Call,
    current_time::Float64
)

    best_id = -1
    best_cost = Inf

    for lift in lifts

        cost = dispatch_cost(
            lift,
            call,
            current_time
        )

        if cost < best_cost
            best_cost = cost
            best_id = lift.id
        end
    end

    return DispatchDecision(
        best_id,
        call.id,
        best_cost
    )
end

###############################################################################
# MULTI-CALL DISPATCH
###############################################################################

function optimise_dispatch(
    lifts::Vector{Lift},
    calls::Vector{Call},
    current_time::Float64
)

    decisions = DispatchDecision[]

    # Process oldest / highest priority calls first.
    ordered_calls = sort(
        calls,
        by = c -> (
            -c.priority,
            c.timestamp
        )
    )

    assigned_lifts = Set{Int}()

    for call in ordered_calls

        decision = best_lift(
            lifts,
            call,
            current_time
        )

        if decision.lift_id != -1

            push!(
                decisions,
                decision
            )

            push!(
                assigned_lifts,
                decision.lift_id
            )
        end
    end

    return decisions
end

###############################################################################
# APPLY DISPATCH
###############################################################################

function assign_call!(
    lift::Lift,
    call::Call
)

    push!(
        lift.target_floors,
        call.floor
    )

    push!(
        lift.target_floors,
        call.destination
    )

    # Remove duplicate destinations
    lift.target_floors =
        unique(lift.target_floors)

    # Establish direction
    if call.floor > lift.floor
        lift.direction = UP
    elseif call.floor < lift.floor
        lift.direction = DOWN
    end

end

###############################################################################
# LIFT MOVEMENT SIMULATION
###############################################################################

function move_lift!(
    lift::Lift,
    dt::Float64
)

    if isempty(lift.target_floors)

        lift.direction = IDLE

        return
    end

    target = lift.target_floors[1]

    distance = target - lift.floor

    if distance == 0

        # Arrived
        popfirst!(lift.target_floors)

        lift.door_open = true

        return
    end

    # Move at constant speed for simple simulation
    floors_per_second =
        LIFT_SPEED / FLOOR_HEIGHT

    movement =
        floors_per_second * dt

    if distance > 0

        lift.direction = UP

        lift.floor += min(
            movement,
            distance
        )

    else

        lift.direction = DOWN

        lift.floor -= min(
            movement,
            -distance
        )
    end

end

###############################################################################
# SIMULATION
###############################################################################

function simulate!(
    lifts::Vector{Lift},
    calls::Vector{Call},
    duration::Float64
)

    time = 0.0

    while time < duration

        decisions = optimise_dispatch(
            lifts,
            calls,
            time
        )

        # Assign calls
        for decision in decisions

            lift = lifts[decision.lift_id]

            call_index = findfirst(
                c -> c.id == decision.call_id,
                calls
            )

            if call_index !== nothing

                call = calls[call_index]

                assign_call!(
                    lift,
                    call
                )

                deleteat!(
                    calls,
                    call_index
                )
            end
        end

        # Move lifts
        for lift in lifts
            move_lift!(
                lift,
                1.0
            )
        end

        time += 1.0

        sleep(0.01)
    end

end

###############################################################################
# EXAMPLE BUILDING
###############################################################################

lifts = Lift[
    Lift(
        1,
        1,
        IDLE,
        12,
        0,
        Int[],
        false
    ),

    Lift(
        2,
        1,
        IDLE,
        12,
        0,
        Int[],
        false
    ),

    Lift(
        3,
        20,
        IDLE,
        20,
        0,
        Int[],
        false
    ),

    Lift(
        4,
        35,
        IDLE,
        20,
        0,
        Int[],
        false
    )
]

calls = Call[
    Call(1, 3, 25, 0.0, 2, 0.0),
    Call(2, 18, 2, 2.0, 1, 0.0),
    Call(3, 32, 45, 5.0, 4, 1.0),
    Call(4, 7, 40, 8.0, 2, 0.0)
]

###############################################################################
# RUN
###############################################################################

simulate!(
    lifts,
    calls,
    120.0
)

println("\nFINAL LIFT STATES")

for lift in lifts

    println(
        "Lift ",
        lift.id,
        " | Floor: ",
        round(lift.floor, digits=2),
        " | Direction: ",
        lift.direction,
        " | Targets: ",
        lift.target_floors
    )

end

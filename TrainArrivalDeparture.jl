module TrainArrivalDeparture

using Printf
using Dates

export Station,
       Service,
       Train,
       Platform,
       StopPlan,
       StationEvent,
       Timetable,
       create_timetable,
       calculate_arrival,
       calculate_departure,
       update_station_stop!,
       dispatch!,
       run_service!,
       print_timetable,
       demo


# ============================================================
# TRAIN ARRIVAL / DEPARTURE CONTROL
#
# Pure Julia
#
# Handles:
#   • Timetabled arrivals
#   • Timetabled departures
#   • Dwell times
#   • Early / late running
#   • Platform occupation
#   • Passenger boarding/alighting
#   • Door closing
#   • Dispatch readiness
#   • Departure sequencing
#   • Recovery from delay
#
# This is a simulation / timetable engine, not a
# safety-certified railway signalling or dispatch system.
# ============================================================


# ============================================================
# STATION
# ============================================================

struct Station

    id::Int
    name::String

    minimum_dwell_s::Float64
    dispatch_buffer_s::Float64
end


# ============================================================
# PLATFORM
# ============================================================

mutable struct Platform

    id::Int
    station_id::Int

    occupied::Bool

    train_id::Union{Nothing,Int}

    scheduled_arrival::Union{Nothing,DateTime}
    scheduled_departure::Union{Nothing,DateTime}

    actual_arrival::Union{Nothing,DateTime}
    actual_departure::Union{Nothing,DateTime}
end


# ============================================================
# TRAIN
# ============================================================

@enum TrainStatus begin
    NOT_STARTED
    APPROACHING
    ARRIVED
    BOARDING
    DOORS_CLOSING
    READY_TO_DEPART
    DEPARTED
    TERMINATED
end


mutable struct Train

    id::Int
    service_id::Int
    headcode::String

    status::TrainStatus

    passengers::Int
    capacity::Int

    current_station::Union{Nothing,Int}
    next_station::Union{Nothing,Int}

    platform_id::Union{Nothing,Int}

    arrival_time::Union{Nothing,DateTime}
    departure_time::Union{Nothing,DateTime}

    delay_s::Float64

    door_open::Bool

    boarding_complete::Bool
    doors_closed::Bool

    dispatch_authorised::Bool
end


# ============================================================
# STOP PLAN
# ============================================================

struct StopPlan

    station_id::Int

    scheduled_arrival::DateTime
    scheduled_departure::DateTime

    minimum_dwell_s::Float64

    boarding_time_s::Float64
    alighting_time_s::Float64

    recovery_allowed_s::Float64
end


# ============================================================
# SERVICE
# ============================================================

struct Service

    id::Int

    headcode::String

    train_id::Int

    stops::Vector{StopPlan}
end


# ============================================================
# EVENT
# ============================================================

struct StationEvent

    train_id::Int
    station_id::Int

    event_type::Symbol

    scheduled_time::DateTime
    actual_time::Union{Nothing,DateTime}

    delay_s::Float64
end


# ============================================================
# TIMETABLE
# ============================================================

mutable struct Timetable

    stations::Dict{Int,Station}
    platforms::Dict{Int,Platform}

    services::Dict{Int,Service}
    trains::Dict{Int,Train}

    events::Vector{StationEvent}
end


function Timetable()

    Timetable(
        Dict{Int,Station}(),
        Dict{Int,Platform}(),
        Dict{Int,Service}(),
        Dict{Int,Train}(),
        StationEvent[]
    )
end


# ============================================================
# ADD STATION
# ============================================================

function add_station!(
    timetable::Timetable,
    station::Station
)

    timetable.stations[station.id] =
        station

    return station.id
end


# ============================================================
# ADD PLATFORM
# ============================================================

function add_platform!(
    timetable::Timetable,
    platform::Platform
)

    timetable.platforms[platform.id] =
        platform

    return platform.id
end


# ============================================================
# ADD TRAIN
# ============================================================

function add_train!(
    timetable::Timetable,
    train::Train
)

    timetable.trains[train.id] =
        train

    return train.id
end


# ============================================================
# ADD SERVICE
# ============================================================

function add_service!(
    timetable::Timetable,
    service::Service
)

    timetable.services[service.id] =
        service

    return service.id
end


# ============================================================
# ARRIVAL CALCULATION
# ============================================================

"""
Calculate actual arrival from scheduled arrival + delay.
"""
function calculate_arrival(
    scheduled::DateTime,
    delay_s::Real
)

    return scheduled +
           Second(
               round(
                   Int,
                   delay_s
               )
           )
end


# ============================================================
# DEPARTURE CALCULATION
# ============================================================

function calculate_departure(
    arrival::DateTime,
    minimum_dwell_s::Real,
    boarding_time_s::Real,
    alighting_time_s::Real,
    recovery_s::Real=0.0
)

    operational_dwell =
        max(
            Float64(minimum_dwell_s),
            Float64(boarding_time_s),
            Float64(alighting_time_s)
        )

    return arrival +
           Second(
               round(
                   Int,
                   operational_dwell +
                   recovery_s
               )
           )
end


# ============================================================
# DWELL TIME OPTIMISATION
# ============================================================

function optimise_dwell(
    stop::StopPlan,
    train::Train
)

    passenger_factor =
        if train.passengers < 100
            0.5
        elseif train.passengers < 400
            1.0
        else
            1.5
        end

    passenger_time =
        max(
            stop.boarding_time_s,
            stop.alighting_time_s
        ) *
        passenger_factor

    dwell =
        max(
            stop.minimum_dwell_s,
            passenger_time
        )

    # Never exceed the timetable recovery allowance
    # unnecessarily.

    return dwell
end


# ============================================================
# PLATFORM AVAILABILITY
# ============================================================

function platform_available(
    timetable::Timetable,
    platform_id::Int
)

    haskey(
        timetable.platforms,
        platform_id
    ) || return false

    return !timetable.platforms[
        platform_id
    ].occupied
end


# ============================================================
# OCCUPY PLATFORM
# ============================================================

function occupy_platform!(
    timetable::Timetable,
    platform_id::Int,
    train_id::Int
)

    platform =
        timetable.platforms[
            platform_id
        ]

    platform.occupied = true
    platform.train_id = train_id

    train =
        timetable.trains[
            train_id
        ]

    train.platform_id =
        platform_id

    return true
end


# ============================================================
# RELEASE PLATFORM
# ============================================================

function release_platform!(
    timetable::Timetable,
    platform_id::Int
)

    platform =
        timetable.platforms[
            platform_id
        ]

    platform.occupied = false
    platform.train_id = nothing

    return true
end


# ============================================================
# ARRIVAL EVENT
# ============================================================

function register_arrival!(
    timetable::Timetable,
    train::Train,
    stop::StopPlan,
    actual_arrival::DateTime
)

    delay =
        Dates.value(
            actual_arrival -
            stop.scheduled_arrival
        ) / 1000

    train.status =
        ARRIVED

    train.current_station =
        stop.station_id

    train.arrival_time =
        actual_arrival

    train.delay_s =
        delay

    train.door_open =
        true

    push!(
        timetable.events,
        StationEvent(
            train.id,
            stop.station_id,
            :ARRIVAL,
            stop.scheduled_arrival,
            actual_arrival,
            delay
        )
    )

    return delay
end


# ============================================================
# PASSENGER ALIGHTING
# ============================================================

function process_alighting!(
    train::Train,
    stop::StopPlan
)

    train.status =
        BOARDING

    # Simplified passenger model.
    # A production system would consume live passenger
    # counts from station systems.

    alighting_fraction =
        clamp(
            0.10 +
            0.40 *
            rand(),
            0.0,
            0.70
        )

    leaving =
        round(
            Int,
            train.passengers *
            alighting_fraction
        )

    train.passengers =
        max(
            0,
            train.passengers -
            leaving
        )

    return leaving
end


# ============================================================
# PASSENGER BOARDING
# ============================================================

function process_boarding!(
    train::Train,
    stop::StopPlan
)

    available =
        train.capacity -
        train.passengers

    boarding =
        min(
            available,
            round(
                Int,
                10 +
                rand() * 60
            )
        )

    train.passengers +=
        boarding

    train.boarding_complete =
        true

    return boarding
end


# ============================================================
# DOOR CLOSURE
# ============================================================

function close_doors!(
    train::Train
)

    train.status =
        DOORS_CLOSING

    train.door_open =
        false

    train.doors_closed =
        true

    return true
end


# ============================================================
# DEPARTURE READINESS
# ============================================================

function departure_ready(
    train::Train,
    stop::StopPlan,
    now::DateTime
)

    train.doors_closed ||
        return false

    train.boarding_complete ||
        return false

    minimum_departure =
        calculate_departure(
            something(
                train.arrival_time,
                stop.scheduled_arrival
            ),
            stop.minimum_dwell_s,
            stop.boarding_time_s,
            stop.alighting_time_s
        )

    return now >= minimum_departure
end


# ============================================================
# DISPATCH AUTHORISATION
# ============================================================

function authorise_dispatch!(
    train::Train
)

    train.dispatch_authorised =
        true

    train.status =
        READY_TO_DEPART

    return true
end


# ============================================================
# DEPARTURE
# ============================================================

function dispatch!(
    timetable::Timetable,
    train::Train,
    stop::StopPlan,
    actual_departure::DateTime
)

    train.dispatch_authorised ||
        throw(
            ArgumentError(
                "Train is not authorised to depart"
            )
        )

    train.status =
        DEPARTED

    train.departure_time =
        actual_departure

    delay =
        Dates.value(
            actual_departure -
            stop.scheduled_departure
        ) / 1000

    train.delay_s =
        delay

    if train.platform_id !== nothing

        platform =
            timetable.platforms[
                train.platform_id
            ]

        platform.actual_departure =
            actual_departure

        release_platform!(
            timetable,
            train.platform_id
        )
    end

    push!(
        timetable.events,
        StationEvent(
            train.id,
            stop.station_id,
            :DEPARTURE,
            stop.scheduled_departure,
            actual_departure,
            delay
        )
    )

    train.current_station =
        stop.station_id

    return delay
end


# ============================================================
# COMPLETE STATION STOP
# ============================================================

function update_station_stop!(
    timetable::Timetable,
    train::Train,
    stop::StopPlan,
    now::DateTime
)

    # -----------------------------------------------
    # ARRIVAL
    # -----------------------------------------------

    if train.status == APPROACHING

        if train.platform_id === nothing

            # Find first available platform.
            candidates =
                [
                    p.id
                    for p in values(
                        timetable.platforms
                    )
                    if p.station_id ==
                       stop.station_id &&
                       !p.occupied
                ]

            isempty(candidates) &&
                return :WAITING_FOR_PLATFORM

            occupy_platform!(
                timetable,
                first(candidates),
                train.id
            )
        end

        register_arrival!(
            timetable,
            train,
            stop,
            now
        )
    end

    # -----------------------------------------------
    # ALIGHTING
    # -----------------------------------------------

    if train.status == ARRIVED

        process_alighting!(
            train,
            stop
        )
    end

    # -----------------------------------------------
    # BOARDING
    # -----------------------------------------------

    if train.status == BOARDING

        process_boarding!(
            train,
            stop
        )
    end

    # -----------------------------------------------
    # DOORS
    # -----------------------------------------------

    if train.boarding_complete &&
       train.door_open

        close_doors!(
            train
        )
    end

    # -----------------------------------------------
    # DISPATCH
    # -----------------------------------------------

    if train.status == DOORS_CLOSING

        if departure_ready(
            train,
            stop,
            now
        )

            authorise_dispatch!(
                train
            )
        end
    end

    if train.status == READY_TO_DEPART

        dispatch!(
            timetable,
            train,
            stop,
            now
        )

        return :DEPARTED
    end

    return train.status
end


# ============================================================
# DELAY RECOVERY
# ============================================================

function calculate_recovery(
    current_delay_s::Float64,
    stop::StopPlan
)

    if current_delay_s <= 0

        return 0.0
    end

    return min(
        current_delay_s,
        stop.recovery_allowed_s
    )
end


# ============================================================
# SERVICE RUNNER
# ============================================================

function run_service!(
    timetable::Timetable,
    service_id::Int;
    start_time=nothing
)

    service =
        timetable.services[
            service_id
        ]

    train =
        timetable.trains[
            service.train_id
        ]

    current_time =
        start_time === nothing ?
        service.stops[1].scheduled_arrival :
        start_time

    train.status =
        APPROACHING

    for stop in service.stops

        # Simulate arrival.
        arrival =
            calculate_arrival(
                stop.scheduled_arrival,
                train.delay_s
            )

        current_time =
            max(
                current_time,
                arrival
            )

        update_station_stop!(
            timetable,
            train,
            stop,
            current_time
        )

        # Calculate dwell.
        dwell =
            optimise_dwell(
                stop,
                train
            )

        recovery =
            calculate_recovery(
                train.delay_s,
                stop
            )

        departure =
            max(
                stop.scheduled_departure,
                current_time +
                Second(
                    round(
                        Int,
                        dwell
                    )
                ) -
                Second(
                    round(
                        Int,
                        recovery
                    )
                )
            )

        # Complete station operation.
        if train.status != DEPARTED

            close_doors!(
                train

            )

            authorise_dispatch!(
                train
            )

            dispatch!(
                timetable,
                train,
                stop,
                departure
            )
        end

        current_time =
            departure

        train.status =
            APPROACHING
    end

    train.status =
        TERMINATED

    return train
end


# ============================================================
# TIMETABLE GENERATOR
# ============================================================

function create_timetable()

    timetable =
        Timetable()

    # Stations

    add_station!(
        timetable,
        Station(
            1,
            "London",
            30.0,
            10.0
        )
    )

    add_station!(
        timetable,
        Station(
            2,
            "Birmingham",
            60.0,
            10.0
        )
    )

    add_station!(
        timetable,
        Station(
            3,
            "Manchester",
            45.0,
            10.0
        )
    )

    # Platforms

    add_platform!(
        timetable,
        Platform(
            1,
            1,
            false,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing
        )
    )

    add_platform!(
        timetable,
        Platform(
            2,
            2,
            false,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing
        )
    )

    add_platform!(
        timetable,
        Platform(
            3,
            3,
            false,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing
        )
    )

    # Train

    train =
        Train(
            1001,
            5001,
            "1A01",
            NOT_STARTED,
            250,
            600,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            0.0,
            false,
            false,
            false,
            false
        )

    add_train!(
        timetable,
        train
    )

    # Timetable

    base =
        DateTime(
            2026,
            8,
            30,
            8,
            0,
            0
        )

    stops = [

        StopPlan(
            1,
            base,
            base + Minute(2),
            30.0,
            30.0,
            20.0,
            0.0
        ),

        StopPlan(
            2,
            base + Minute(80),
            base + Minute(82),
            45.0,
            45.0,
            30.0,
            120.0
        ),

        StopPlan(
            3,
            base + Minute(140),
            base + Minute(143),
            45.0,
            45.0,
            30.0,
            120.0
        )
    ]

    service =
        Service(
            5001,
            "1A01",
            1001,
            stops
        )

    add_service!(
        timetable,
        service
    )

    return timetable
end


# ============================================================
# PRINT TIMETABLE
# ============================================================

function print_timetable(
    timetable::Timetable
)

    println()
    println(
        "=============================================================="
    )

    println(
        "                TRAIN ARRIVAL / DEPARTURE"
    )

    println(
        "=============================================================="
    )

    for service in values(
        timetable.services
    )

        train =
            timetable.trains[
                service.train_id
            ]

        println()
        println(
            "Service: ",
            service.headcode
        )

        println(
            "Train:   ",
            train.id
        )

        for stop in service.stops

            @printf(
                "Station %-15s  ARR %s  DEP %s\n",
                timetable.stations[
                    stop.station_id
                ].name,
                stop.scheduled_arrival,
                stop.scheduled_departure
            )
        end
    end

    println()
    println(
        "=============================================================="
    )
end


# ============================================================
# EVENT LOG
# ============================================================

function print_events(
    timetable::Timetable
)

    println()
    println(
        "EVENT LOG"
    )

    println(
        "--------------------------------------------------------------"
    )

    for event in timetable.events

        station =
            timetable.stations[
                event.station_id
            ]

        println(
            event.actual_time,
            " | Train ",
            event.train_id,
            " | ",
            station.name,
            " | ",
            event.event_type,
            " | delay ",
            round(
                event.delay_s,
                digits=1
            ),
            " s"
        )
    end
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    timetable =
        create_timetable()

    print_timetable(
        timetable
    )

    println()
    println(
        "Running service..."
    )

    run_service!(
        timetable,
        5001
    )

    print_events(
        timetable
    )

    train =
        timetable.trains[
            1001
        ]

    println()
    println(
        "Final train status: ",
        train.status
    )

    println(
        "Passengers: ",
        train.passengers
    )

    println(
        "Final delay: ",
        round(
            train.delay_s,
            digits=1
        ),
        " seconds"
    )

    return timetable
end


end # module


# ============================================================
# RUN
# ============================================================

using .TrainArrivalDeparture

TrainArrivalDeparture.demo()

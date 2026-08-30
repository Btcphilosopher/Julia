```julia
# ================================================================
# FOOTBALL ANALYTICS ENGINE
# Julia-based football data analytics prototype
#
# Features:
#
#   Match event processing
#   Expected Goals (xG)
#   Expected Assists (xA)
#   Shot quality
#   Possession
#   Progressive actions
#   Pressures
#   Tackles
#   Interceptions
#   Key passes
#   Player ratings
#   Team attacking/defensive ratings
#   Player contribution index
#   Scouting score
#
# No external packages required.
#
# Real deployment:
#   Replace simulated events with Opta / StatsBomb /
#   Wyscout / provider-specific event feeds.
# ================================================================

using Random
using Statistics
using Printf

Random.seed!(1234)

# ================================================================
# ENUMS
# ================================================================

@enum EventType begin
    SHOT
    PASS
    CARRY
    TACKLE
    INTERCEPTION
    PRESSURE
    FOUL
    DRIBBLE
end

@enum ShotType begin
    OPEN_PLAY
    SET_PIECE
    PENALTY
end

# ================================================================
# PLAYER
# ================================================================

mutable struct Player

    id::Int

    name::String

    team::String

    position::String

    minutes::Float64

    goals::Int

    assists::Int

    shots::Int

    xg::Float64

    xa::Float64

    passes::Int

    progressive_passes::Int

    carries::Int

    progressive_carries::Int

    tackles::Int

    interceptions::Int

    pressures::Int

    key_passes::Int
end

# ================================================================
# EVENT
# ================================================================

struct Event

    minute::Float64

    team::String

    player_id::Int

    event_type::EventType

    x::Float64

    y::Float64

    end_x::Float64

    end_y::Float64

    shot_type::Union{
        Nothing,
        ShotType
    }

    body_part::String

    under_pressure::Bool

    successful::Bool

    goal::Bool
end

# ================================================================
# MATCH
# ================================================================

struct Match

    home_team::String

    away_team::String

    events::Vector{Event}

    players::Dict{Int,Player}
end

# ================================================================
# BASIC MATHEMATICS
# ================================================================

function sigmoid(x)

    return 1.0 /
        (
            1.0 +
            exp(-x)
        )
end

# ================================================================
# DISTANCE TO GOAL
#
# Pitch coordinate system:
#   x = 0   defensive goal
#   x = 100 attacking goal
# ================================================================

function distance_to_goal(
    x,
    y
)

    goal_x = 100.0

    goal_y = 50.0

    return sqrt(
        (
            goal_x - x
        )^2 +
        (
            goal_y - y
        )^2
    )
end

# ================================================================
# ANGLE TO GOAL
# ================================================================

function shot_angle(
    x,
    y
)

    goal_width = 7.32

    left_post =
        (
            100.0,
            50.0 -
            goal_width / 2
        )

    right_post =
        (
            100.0,
            50.0 +
            goal_width / 2
        )

    a =
        atan(
            left_post[2] - y,
            left_post[1] - x
        )

    b =
        atan(
            right_post[2] - y,
            right_post[1] - x
        )

    return abs(
        b - a
    )
end

# ================================================================
# SHOT TYPE EFFECT
# ================================================================

function shot_type_effect(
    shot_type
)

    if shot_type ==
       PENALTY

        return 2.0

    elseif shot_type ==
           SET_PIECE

        return -0.35

    else

        return 0.0
    end
end

# ================================================================
# BODY PART EFFECT
# ================================================================

function body_part_effect(
    body_part
)

    if body_part == "foot"

        return 0.25

    elseif body_part == "head"

        return -0.80

    else

        return -0.30
    end
end

# ================================================================
# xG MODEL
#
# Deliberately simple interpretable baseline.
#
# Production system:
#   Train against historical shot outcomes.
# ================================================================

function calculate_xg(
    event::Event
)

    if event.event_type != SHOT

        return 0.0
    end

    d =
        distance_to_goal(
            event.x,
            event.y
        )

    angle =
        shot_angle(
            event.x,
            event.y
        )

    pressure =
        event.under_pressure ?
        -0.60 :
        0.0

    # Logistic model

    z =
        2.5 -
        0.085 * d +
        1.20 * angle +
        shot_type_effect(
            event.shot_type
        ) +
        body_part_effect(
            event.body_part
        ) +
        pressure

    return clamp(
        sigmoid(z),
        0.001,
        0.999
    )
end

# ================================================================
# xA MODEL
#
# Simplified assist quality estimate.
# ================================================================

function calculate_xa(
    event::Event
)

    if event.event_type != PASS

        return 0.0
    end

    # Progressive passes have greater attacking value.

    progress =
        max(
            0.0,
            event.end_x -
            event.x
        )

    base =
        0.005 +
        0.003 *
        progress

    pressure_bonus =
        event.under_pressure ?
        0.015 :
        0.0

    return clamp(
        base +
        pressure_bonus,
        0.0,
        0.50
    )
end

# ================================================================
# PROGRESSIVE ACTION
# ================================================================

function progressive_action(
    event::Event
)

    if event.event_type ∉
       (PASS, CARRY)

        return false
    end

    return (
        event.end_x -
        event.x
    ) >= 10.0
end

# ================================================================
# EVENT PROCESSOR
# ================================================================

function process_events!(
    match::Match
)

    for event in
        match.events

        if !haskey(
            match.players,
            event.player_id
        )

            continue
        end

        player =
            match.players[
                event.player_id
            ]

        # --------------------------------------------------------
        # SHOT
        # --------------------------------------------------------

        if event.event_type ==
           SHOT

            player.shots += 1

            xg =
                calculate_xg(
                    event
                )

            player.xg +=
                xg

            if event.goal

                player.goals += 1
            end

        # --------------------------------------------------------
        # PASS
        # --------------------------------------------------------

        elseif event.event_type ==
               PASS

            player.passes += 1

            player.xa +=
                calculate_xa(
                    event
                )

            if progressive_action(
                event
            )

                player.progressive_passes += 1
            end

            if event.successful &&
               calculate_xa(event) >
               0.08

                player.key_passes += 1
            end

        # --------------------------------------------------------
        # CARRY
        # --------------------------------------------------------

        elseif event.event_type ==
               CARRY

            player.carries += 1

            if progressive_action(
                event
            )

                player.progressive_carries += 1
            end

        # --------------------------------------------------------
        # TACKLE
        # --------------------------------------------------------

        elseif event.event_type ==
               TACKLE

            if event.successful

                player.tackles += 1
            end

        # --------------------------------------------------------
        # INTERCEPTION
        # --------------------------------------------------------

        elseif event.event_type ==
               INTERCEPTION

            if event.successful

                player.interceptions += 1
            end

        # --------------------------------------------------------
        # PRESSURE
        # --------------------------------------------------------

        elseif event.event_type ==
               PRESSURE

            player.pressures += 1
        end
    end

    return match
end

# ================================================================
# TEAM METRICS
# ================================================================

struct TeamMetrics

    team::String

    goals::Int

    xg::Float64

    xga::Float64

    shots::Int

    possession::Float64

    progressive_actions::Int

    pressures::Int

    tackles::Int

    interceptions::Int
end

# ================================================================
# TEAM ANALYSIS
# ================================================================

function team_metrics(
    match::Match,
    team::String
)

    own_events =
        filter(
            e -> e.team == team,
            match.events
        )

    opponent_events =
        filter(
            e -> e.team != team,
            match.events
        )

    goals =
        count(
            e ->
                e.event_type == SHOT &&
                e.goal,
            own_events
        )

    xg =
        sum(
            calculate_xg(e)
            for e in own_events
        )

    xga =
        sum(
            calculate_xg(e)
            for e in opponent_events
        )

    shots =
        count(
            e ->
                e.event_type == SHOT,
            own_events
        )

    progressive =
        count(
            e ->
                progressive_action(e),
            own_events
        )

    pressures =
        count(
            e ->
                e.event_type == PRESSURE,
            own_events
        )

    tackles =
        count(
            e ->
                e.event_type == TACKLE &&
                e.successful,
            own_events
        )

    interceptions =
        count(
            e ->
                e.event_type == INTERCEPTION &&
                e.successful,
            own_events
        )

    # Event share as a simple possession proxy

    total_passes =
        count(
            e ->
                e.event_type == PASS,
            match.events
        )

    team_passes =
        count(
            e ->
                e.event_type == PASS &&
                e.team == team,
            match.events
        )

    possession =
        100.0 *
        team_passes /
        max(
            total_passes,
            1
        )

    return TeamMetrics(

        team,

        goals,

        xg,

        xga,

        shots,

        possession,

        progressive,

        pressures,

        tackles,

        interceptions
    )
end

# ================================================================
# PLAYER ANALYTICS
# ================================================================

struct PlayerAnalytics

    player_id::Int

    name::String

    position::String

    team::String

    goals_per90::Float64

    xg_per90::Float64

    xa_per90::Float64

    progressive_actions_per90::Float64

    pressures_per90::Float64

    tackles_per90::Float64

    interceptions_per90::Float64

    finishing_delta::Float64

    attacking_score::Float64

    defensive_score::Float64

    overall_score::Float64
end

# ================================================================
# PLAYER RATING
# ================================================================

function analyse_player(
    player::Player
)

    minutes =
        max(
            player.minutes,
            1.0
        )

    factor =
        90.0 /
        minutes

    goals90 =
        player.goals *
        factor

    xg90 =
        player.xg *
        factor

    xa90 =
        player.xa *
        factor

    progressive90 =
        (
            player.progressive_passes +
            player.progressive_carries
        ) *
        factor

    pressures90 =
        player.pressures *
        factor

    tackles90 =
        player.tackles *
        factor

    interceptions90 =
        player.interceptions *
        factor

    finishing_delta =
        goals90 -
        xg90

    attacking_score =
        30.0 * xg90 +
        20.0 * xa90 +
        5.0 * progressive90 +
        10.0 * player.key_passes *
        factor +
        15.0 *
        max(
            finishing_delta,
            -0.5
        )

    defensive_score =
        2.0 * pressures90 +
        5.0 * tackles90 +
        6.0 * interceptions90

    overall =
        attacking_score +
        defensive_score

    return PlayerAnalytics(

        player.id,

        player.name,

        player.position,

        player.team,

        goals90,

        xg90,

        xa90,

        progressive90,

        pressures90,

        tackles90,

        interceptions90,

        finishing_delta,

        attacking_score,

        defensive_score,

        overall
    )
end

# ================================================================
# PLAYER LEADERBOARD
# ================================================================

function player_leaderboard(
    match::Match
)

    results =
        PlayerAnalytics[]

    for player in
        values(match.players)

        push!(
            results,
            analyse_player(
                player
            )
        )
    end

    sort!(
        results,
        by = x -> x.overall_score,
        rev = true
    )

    return results
end

# ================================================================
# SIMULATED EVENT GENERATOR
# ================================================================

function random_player(
    players,
    team
)

    candidates =
        [
            p.id
            for p in
            values(players)
            if p.team == team
        ]

    return rand(
        candidates
    )
end


function generate_events(
    players,
    home,
    away,
    n = 1200
)

    events =
        Event[]

    teams =
        [home, away]

    for i in 1:n

        team =
            rand(teams)

        player_id =
            random_player(
                players,
                team
            )

        minute =
            rand() *
            90.0

        event_roll =
            rand()

        # --------------------------------------------------------
        # SHOT
        # --------------------------------------------------------

        if event_roll < 0.06

            x =
                rand(
                    60.0:0.5:96.0
                )

            y =
                rand(
                    15.0:0.5:85.0
                )

            shot_types =
                [
                    OPEN_PLAY,
                    OPEN_PLAY,
                    OPEN_PLAY,
                    SET_PIECE,
                    PENALTY
                ]

            shot_type =
                rand(
                    shot_types
                )

            body =
                rand(
                    [
                        "foot",
                        "foot",
                        "foot",
                        "head"
                    ]
                )

            pressure =
                rand() < 0.30

            temporary =
                Event(

                    minute,

                    team,

                    player_id,

                    SHOT,

                    x,

                    y,

                    100.0,

                    50.0,

                    shot_type,

                    body,

                    pressure,

                    true,

                    false
                )

            xg =
                calculate_xg(
                    temporary
                )

            goal =
                rand() <
                xg

            push!(
                events,
                Event(

                    minute,

                    team,

                    player_id,

                    SHOT,

                    x,

                    y,

                    100.0,

                    50.0,

                    shot_type,

                    body,

                    pressure,

                    true,

                    goal
                )
            )

        # --------------------------------------------------------
        # PASS
        # --------------------------------------------------------

        elseif event_roll < 0.65

            x =
                rand(
                    5.0:1.0:95.0
                )

            y =
                rand(
                    5.0:1.0:95.0
                )

            forward =
                rand(
                    -5.0:1.0:25.0
                )

            end_x =
                clamp(
                    x + forward,
                    0.0,
                    100.0
                )

            end_y =
                clamp(
                    y +
                    rand(-20.0:1.0:20.0),
                    0.0,
                    100.0
                )

            push!(
                events,
                Event(

                    minute,

                    team,

                    player_id,

                    PASS,

                    x,

                    y,

                    end_x,

                    end_y,

                    nothing,

                    "",

                    rand() < 0.20,

                    rand() < 0.85,

                    false
                )
            )

        # --------------------------------------------------------
        # CARRY
        # --------------------------------------------------------

        elseif event_roll < 0.75

            x =
                rand(
                    10.0:1.0:90.0
                )

            y =
                rand(
                    5.0:1.0:95.0
                )

            end_x =
                clamp(
                    x +
                    rand(
                        1.0:1.0:20.0
                    ),
                    0.0,
                    100.0
                )

            push!(
                events,
                Event(

                    minute,

                    team,

                    player_id,

                    CARRY,

                    x,

                    y,

                    end_x,

                    y,

                    nothing,

                    "",

                    rand() < 0.25,

                    true,

                    false
                )
            )

        # --------------------------------------------------------
        # PRESSURE
        # --------------------------------------------------------

        elseif event_roll < 0.88

            push!(
                events,
                Event(

                    minute,

                    team,

                    player_id,

                    PRESSURE,

                    rand() * 100,

                    rand() * 100,

                    0.0,

                    0.0,

                    nothing,

                    "",

                    true,

                    true,

                    false
                )
            )

        # --------------------------------------------------------
        # DEFENSIVE ACTION
        # --------------------------------------------------------

        else

            defensive_event =
                rand(
                    [
                        TACKLE,
                        INTERCEPTION
                    ]
                )

            push!(
                events,
                Event(

                    minute,

                    team,

                    player_id,

                    defensive_event,

                    rand() * 100,

                    rand() * 100,

                    0.0,

                    0.0,

                    nothing,

                    "",

                    rand() < 0.30,

                    rand() < 0.70,

                    false
                )
            )
        end
    end

    return events
end

# ================================================================
# CREATE SQUADS
# ================================================================

function create_players()

    players =
        Dict{Int,Player}()

    names =
        [
            "Alexander",
            "Benjamin",
            "Charlie",
            "Daniel",
            "Edward",
            "Frederick",
            "George",
            "Henry",
            "James",
            "Thomas",
            "William"
        ]

    positions =
        [
            "GK",
            "CB",
            "CB",
            "FB",
            "FB",
            "CM",
            "CM",
            "AM",
            "WG",
            "ST",
            "ST"
        ]

    id = 1

    for team in
        ["NORTH CITY", "SOUTH UNITED"]

        for i in 1:11

            players[id] =
                Player(

                    id,

                    names[
                        mod1(
                            id,
                            length(names)
                        )
                    ] *
                    " " *
                    string(id),

                    team,

                    positions[i],

                    90.0,

                    0,

                    0,

                    0,

                    0.0,

                    0.0,

                    0,

                    0,

                    0,

                    0,

                    0,

                    0,

                    0,

                    0
                )

            id += 1
        end
    end

    return players
end

# ================================================================
# REPORT
# ================================================================

function print_report(
    match::Match
)

    println()
    println(
        "=============================================================="
    )

    println(
        "                 FOOTBALL ANALYTICS"
    )

    println(
        "=============================================================="
    )

    home =
        team_metrics(
            match,
            match.home_team
        )

    away =
        team_metrics(
            match,
            match.away_team
        )

    println()
    println(
        "TEAM ANALYSIS"
    )

    @printf(
        "%-18s %6s %8s %8s %10s\n",
        "Team",
        "Goals",
        "xG",
        "xGA",
        "Possession"
    )

    for t in
        [home, away]

        @printf(
            "%-18s %6d %8.2f %8.2f %9.1f%%\n",

            t.team,

            t.goals,

            t.xg,

            t.xga,

            t.possession
        )
    end

    println()
    println(
        "PLAYER LEADERBOARD"
    )

    println(
        "--------------------------------------------------------------"
    )

    @printf(
        "%-20s %-18s %6s %6s %6s %8s\n",
        "Player",
        "Team",
        "xG/90",
        "xA/90",
        "Prog/90",
        "Rating"
    )

    leaderboard =
        player_leaderboard(
            match
        )

    for player in
        leaderboard[1:min(15, length(leaderboard))]

        @printf(
            "%-20s %-18s %6.2f %6.2f %6.2f %8.2f\n",

            player.name,

            player.team,

            player.xg_per90,

            player.xa_per90,

            player.progressive_actions_per90,

            player.overall_score
        )
    end

    println(
        "=============================================================="
    )
end

# ================================================================
# MAIN
# ================================================================

println(
    "Starting Football Analytics Engine..."
)

players =
    create_players()

events =
    generate_events(
        players,
        "NORTH CITY",
        "SOUTH UNITED",
        1800
    )

match =
    Match(

        "NORTH CITY",

        "SOUTH UNITED",

        events,

        players
    )

process_events!(
    match
)

print_report(
    match
)
```


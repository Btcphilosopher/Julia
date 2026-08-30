module JuliaNPC

using Random
using Statistics
using LinearAlgebra

export NPC,
       NPCBrain,
       NPCAction,
       NPCWorld,
       train!,
       predict,
       update!,
       step!,
       add_npc!,
       nearest_enemy,
       observe,
       reset!,
       demo

# ============================================================
# NPC MACHINE-LEARNING GAME ENGINE
#
# Pure Julia
#
# A lightweight reinforcement-learning NPC system using:
#
#   • Q-learning
#   • neural-network-style policy approximation
#   • spatial awareness
#   • needs / state
#   • reward signals
#   • exploration
#   • personality parameters
#   • combat / movement decisions
#
# No external packages required.
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum NPCAction begin
    IDLE
    WANDER
    PATROL
    APPROACH
    RETREAT
    ATTACK
    DEFEND
    SEARCH
    FLEE
end


# ============================================================
# NPC BRAIN
# ============================================================

mutable struct NPCBrain

    # Q-table:
    # state -> action values
    qtable::Dict{Tuple,Vector{Float64}}

    learning_rate::Float64
    discount_factor::Float64
    exploration_rate::Float64

    exploration_decay::Float64
    minimum_exploration::Float64

    reward_scale::Float64

    episodes::Int
end


function NPCBrain(;
    learning_rate=0.12,
    discount_factor=0.94,
    exploration_rate=0.25,
    exploration_decay=0.995,
    minimum_exploration=0.02,
    reward_scale=1.0
)

    NPCBrain(
        Dict{Tuple,Vector{Float64}}(),
        learning_rate,
        discount_factor,
        exploration_rate,
        exploration_decay,
        minimum_exploration,
        reward_scale,
        0
    )
end


# ============================================================
# NPC
# ============================================================

mutable struct NPC

    id::Int
    name::String

    x::Float64
    y::Float64

    health::Float64
    max_health::Float64

    stamina::Float64
    max_stamina::Float64

    hunger::Float64
    fatigue::Float64
    aggression::Float64
    bravery::Float64
    curiosity::Float64

    vision_range::Float64
    attack_range::Float64

    brain::NPCBrain

    current_action::NPCAction

    target_id::Union{Nothing,Int}

    alive::Bool

    experience::Float64
    reward_accumulator::Float64
end


function NPC(
    id::Int,
    name::String,
    x::Real,
    y::Real;
    health=100.0,
    stamina=100.0,
    hunger=0.0,
    fatigue=0.0,
    aggression=0.5,
    bravery=0.5,
    curiosity=0.5,
    vision_range=20.0,
    attack_range=2.0
)

    NPC(
        id,
        name,
        Float64(x),
        Float64(y),

        Float64(health),
        Float64(health),

        Float64(stamina),
        Float64(stamina),

        Float64(hunger),
        Float64(fatigue),

        Float64(aggression),
        Float64(bravery),
        Float64(curiosity),

        Float64(vision_range),
        Float64(attack_range),

        NPCBrain(),

        IDLE,
        nothing,

        true,

        0.0,
        0.0
    )
end


# ============================================================
# WORLD
# ============================================================

mutable struct NPCWorld

    npcs::Dict{Int,NPC}

    width::Float64
    height::Float64

    tick::Int

    combat_reward::Float64
    survival_reward::Float64
    exploration_reward::Float64

    movement_speed::Float64
end


function NPCWorld(
    width::Real,
    height::Real
)

    NPCWorld(
        Dict{Int,NPC}(),
        Float64(width),
        Float64(height),
        0,
        10.0,
        0.02,
        0.1,
        1.0
    )
end


function add_npc!(
    world::NPCWorld,
    npc::NPC
)

    world.npcs[npc.id] = npc

    return npc.id
end


# ============================================================
# DISTANCE
# ============================================================

function distance(
    a::NPC,
    b::NPC
)

    sqrt(
        (a.x - b.x)^2 +
        (a.y - b.y)^2
    )
end


# ============================================================
# NEAREST ENEMY
# ============================================================

function nearest_enemy(
    world::NPCWorld,
    npc::NPC
)

    best_id = nothing
    best_distance = Inf

    for (id, other) in world.npcs

        id == npc.id && continue

        !other.alive && continue

        d = distance(npc, other)

        if d <= npc.vision_range &&
           d < best_distance

            best_distance = d
            best_id = id
        end
    end

    return best_id
end


# ============================================================
# OBSERVATION
# ============================================================

"""
Convert the continuous game world into a discrete ML state.

This makes the Q-learning system extremely lightweight.
"""

function observe(
    world::NPCWorld,
    npc::NPC
)

    enemy_id = nearest_enemy(world, npc)

    enemy_distance = 999.0

    if enemy_id !== nothing
        enemy_distance =
            distance(
                npc,
                world.npcs[enemy_id]
            )
    end

    health_state =
        npc.health < 25 ? 0 :
        npc.health < 60 ? 1 :
        2

    stamina_state =
        npc.stamina < 20 ? 0 :
        npc.stamina < 60 ? 1 :
        2

    enemy_state =
        enemy_id === nothing ? 0 :
        enemy_distance <= npc.attack_range ? 2 :
        1

    hunger_state =
        npc.hunger > 80 ? 2 :
        npc.hunger > 50 ? 1 :
        0

    fatigue_state =
        npc.fatigue > 80 ? 2 :
        npc.fatigue > 50 ? 1 :
        0

    return (
        health_state,
        stamina_state,
        enemy_state,
        hunger_state,
        fatigue_state,
        round(npc.aggression, digits=1),
        round(npc.bravery, digits=1)
    )
end


# ============================================================
# Q-TABLE INITIALISATION
# ============================================================

function ensure_state!(
    brain::NPCBrain,
    state
)

    if !haskey(brain.qtable, state)

        brain.qtable[state] =
            zeros(Float64, 9)
    end

    return brain.qtable[state]
end


# ============================================================
# POLICY
# ============================================================

function predict(
    brain::NPCBrain,
    state
)

    values = ensure_state!(
        brain,
        state
    )

    return values
end


function choose_action(
    brain::NPCBrain,
    state
)

    values = predict(
        brain,
        state
    )

    if rand() < brain.exploration_rate

        return NPCAction(
            rand(0:8)
        )

    end

    return NPCAction(
        argmax(values) - 1
    )
end


# ============================================================
# REWARD
# ============================================================

function calculate_reward(
    world::NPCWorld,
    npc::NPC,
    previous_health::Float64,
    action::NPCAction
)

    reward = 0.0

    # Survival
    if npc.alive
        reward += world.survival_reward
    end

    # Damage taken
    damage =
        previous_health -
        npc.health

    if damage > 0
        reward -= damage * 0.10
    end

    # Healthy combat behaviour
    if action == ATTACK &&
       npc.target_id !== nothing

        reward +=
            npc.aggression *
            world.combat_reward
    end

    # Exploration
    if action == WANDER ||
       action == SEARCH

        reward +=
            npc.curiosity *
            world.exploration_reward
    end

    # Bad physiological state
    reward -=
        npc.fatigue * 0.005

    reward -=
        npc.hunger * 0.003

    return reward
end


# ============================================================
# Q-LEARNING UPDATE
# ============================================================

function update!(
    brain::NPCBrain,
    state,
    action::NPCAction,
    reward::Real,
    next_state
)

    q = ensure_state!(
        brain,
        state
    )

    next_q = ensure_state!(
        brain,
        next_state
    )

    a = Int(action) + 1

    old_value = q[a]

    target =
        reward +
        brain.discount_factor *
        maximum(next_q)

    q[a] =
        old_value +
        brain.learning_rate *
        (target - old_value)

    brain.episodes += 1

    brain.exploration_rate =
        max(
            brain.minimum_exploration,
            brain.exploration_rate *
            brain.exploration_decay
        )

    return q[a]
end


# ============================================================
# MOVEMENT
# ============================================================

function move_towards!(
    npc::NPC,
    target::NPC,
    speed::Float64
)

    dx = target.x - npc.x
    dy = target.y - npc.y

    d = sqrt(dx^2 + dy^2)

    if d < 1e-9
        return
    end

    npc.x += speed * dx / d
    npc.y += speed * dy / d
end


function move_randomly!(
    world::NPCWorld,
    npc::NPC,
    speed::Float64
)

    angle = rand() * 2π

    npc.x += cos(angle) * speed
    npc.y += sin(angle) * speed

    npc.x = clamp(
        npc.x,
        0.0,
        world.width
    )

    npc.y = clamp(
        npc.y,
        0.0,
        world.height
    )
end


function retreat_from!(
    npc::NPC,
    target::NPC,
    speed::Float64
)

    dx = npc.x - target.x
    dy = npc.y - target.y

    d = sqrt(dx^2 + dy^2)

    d < 1e-9 && return

    npc.x += speed * dx / d
    npc.y += speed * dy / d
end


# ============================================================
# COMBAT
# ============================================================

function attack!(
    npc::NPC,
    target::NPC
)

    d = distance(npc, target)

    if d > npc.attack_range
        return 0.0
    end

    damage =
        5.0 +
        10.0 *
        npc.aggression +
        rand() * 5.0

    target.health -= damage

    if target.health <= 0

        target.health = 0
        target.alive = false
    end

    return damage
end


# ============================================================
# NPC DECISION EXECUTION
# ============================================================

function execute_action!(
    world::NPCWorld,
    npc::NPC,
    action::NPCAction
)

    npc.current_action = action

    enemy_id =
        nearest_enemy(
            world,
            npc
        )

    if action == IDLE

        npc.stamina =
            min(
                npc.max_stamina,
                npc.stamina + 1.0
            )

    elseif action == WANDER

        move_randomly!(
            world,
            npc,
            world.movement_speed
        )

    elseif action == PATROL

        move_randomly!(
            world,
            npc,
            world.movement_speed * 0.7
        )

    elseif action == APPROACH

        if enemy_id !== nothing

            target =
                world.npcs[enemy_id]

            move_towards!(
                npc,
                target,
                world.movement_speed
            )

            npc.target_id = enemy_id
        end

    elseif action == RETREAT ||
           action == FLEE

        if enemy_id !== nothing

            target =
                world.npcs[enemy_id]

            retreat_from!(
                npc,
                target,
                world.movement_speed
            )

            npc.target_id = enemy_id
        end

    elseif action == ATTACK

        if enemy_id !== nothing

            target =
                world.npcs[enemy_id]

            if distance(npc, target) <=
               npc.attack_range

                attack!(
                    npc,
                    target
                )

                npc.target_id =
                    enemy_id
            end
        end

    elseif action == DEFEND

        npc.stamina =
            min(
                npc.max_stamina,
                npc.stamina + 0.5
            )

    elseif action == SEARCH

        move_randomly!(
            world,
            npc,
            world.movement_speed * 0.5
        )
    end

    return nothing
end


# ============================================================
# NPC INTERNAL STATE
# ============================================================

function update_needs!(
    npc::NPC
)

    npc.hunger =
        clamp(
            npc.hunger + 0.05,
            0.0,
            100.0
        )

    if npc.current_action == WANDER ||
       npc.current_action == PATROL ||
       npc.current_action == APPROACH ||
       npc.current_action == RETREAT ||
       npc.current_action == FLEE

        npc.fatigue =
            clamp(
                npc.fatigue + 0.10,
                0.0,
                100.0
            )

        npc.stamina =
            max(
                0.0,
                npc.stamina - 0.5
            )

    elseif npc.current_action == IDLE ||
           npc.current_action == DEFEND

        npc.fatigue =
            max(
                0.0,
                npc.fatigue - 0.5
            )

        npc.stamina =
            min(
                npc.max_stamina,
                npc.stamina + 1.0
            )
    end
end


# ============================================================
# HIGH-LEVEL DECISION MODIFIER
# ============================================================

function personality_override(
    npc::NPC,
    action::NPCAction
)

    # Very low health:
    if npc.health < 20 &&
       npc.bravery < 0.7

        return FLEE
    end

    # Extremely aggressive NPCs attack nearby enemies.
    if npc.aggression > 0.85 &&
       action != ATTACK

        return ATTACK
    end

    # Exhausted NPCs rest.
    if npc.stamina < 10 &&
       npc.fatigue > 70

        return DEFEND
    end

    return action
end


# ============================================================
# ONE SIMULATION TICK
# ============================================================

function step!(
    world::NPCWorld
)

    world.tick += 1

    ids = collect(keys(world.npcs))

    for id in ids

        npc = world.npcs[id]

        !npc.alive && continue

        previous_health =
            npc.health

        state =
            observe(
                world,
                npc
            )

        action =
            choose_action(
                npc.brain,
                state
            )

        action =
            personality_override(
                npc,
                action
            )

        execute_action!(
            world,
            npc,
            action
        )

        update_needs!(
            npc
        )

        next_state =
            observe(
                world,
                npc
            )

        reward =
            calculate_reward(
                world,
                npc,
                previous_health,
                action
            )

        update!(
            npc.brain,
            state,
            action,
            reward,
            next_state
        )

        npc.reward_accumulator +=
            reward

        npc.experience +=
            abs(reward)
    end

    return world
end


# ============================================================
# TRAINING
# ============================================================

function train!(
    world::NPCWorld;
    episodes::Int=1000,
    steps_per_episode::Int=500
)

    for episode in 1:episodes

        reset!(world)

        for step in 1:steps_per_episode

            step!(world)

            alive =
                count(
                    npc -> npc.alive,
                    values(world.npcs)
                )

            alive == 0 &&
                break
        end

        # Training progress
        if episode % 100 == 0

            println(
                "Episode ",
                episode,
                "/",
                episodes,
                " | exploration=",
                round(
                    mean(
                        npc.brain.exploration_rate
                        for npc in values(world.npcs)
                    ),
                    digits=4
                )
            )
        end
    end

    return world
end


# ============================================================
# RESET WORLD
# ============================================================

function reset!(
    world::NPCWorld
)

    world.tick = 0

    for npc in values(world.npcs)

        npc.health =
            npc.max_health

        npc.stamina =
            npc.max_stamina

        npc.hunger = 0.0
        npc.fatigue = 0.0

        npc.current_action =
            IDLE

        npc.target_id =
            nothing

        npc.alive = true

        npc.reward_accumulator =
            0.0

        npc.x =
            rand() * world.width

        npc.y =
            rand() * world.height
    end

    return world
end


# ============================================================
# DIAGNOSTICS
# ============================================================

function npc_status(
    npc::NPC
)

    return (
        id = npc.id,
        name = npc.name,
        position = (npc.x, npc.y),
        health = npc.health,
        stamina = npc.stamina,
        hunger = npc.hunger,
        fatigue = npc.fatigue,
        action = npc.current_action,
        target = npc.target_id,
        alive = npc.alive,
        exploration =
            npc.brain.exploration_rate,
        learned_states =
            length(npc.brain.qtable),
        reward =
            npc.reward_accumulator
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    Random.seed!(42)

    world =
        NPCWorld(
            100.0,
            100.0
        )

    # --------------------------------------------------------
    # Create NPCs with different personalities.
    # --------------------------------------------------------

    soldier =
        NPC(
            1,
            "Arthur",
            20,
            20;
            aggression=0.85,
            bravery=0.90,
            curiosity=0.30
        )

    scout =
        NPC(
            2,
            "Meredith",
            70,
            70;
            aggression=0.30,
            bravery=0.60,
            curiosity=0.95
        )

    civilian =
        NPC(
            3,
            "Thomas",
            50,
            50;
            aggression=0.10,
            bravery=0.20,
            curiosity=0.60
        )

    enemy =
        NPC(
            4,
            "Enemy",
            60,
            60;
            aggression=0.75,
            bravery=0.80,
            curiosity=0.20
        )

    add_npc!(
        world,
        soldier
    )

    add_npc!(
        world,
        scout
    )

    add_npc!(
        world,
        civilian
    )

    add_npc!(
        world,
        enemy
    )

    println()
    println("==========================================")
    println("      JULIA MACHINE-LEARNING NPC DEMO")
    println("==========================================")

    println()
    println("Training NPC brains...")

    train!(
        world;
        episodes=500,
        steps_per_episode=200
    )

    println()
    println("Training complete.")
    println()

    # --------------------------------------------------------
    # Run trained NPCs.
    # --------------------------------------------------------

    reset!(world)

    for tick in 1:100

        step!(world)

        if tick % 10 == 0

            println()
            println("TICK ", tick)

            for npc in values(world.npcs)

                println(
                    npc.name,
                    " | HP=",
                    round(npc.health, digits=1),
                    " | action=",
                    npc.current_action,
                    " | pos=(",
                    round(npc.x, digits=1),
                    ", ",
                    round(npc.y, digits=1),
                    ") | states=",
                    length(npc.brain.qtable)
                )
            end
        end
    end

    return world
end


end # module


# ============================================================
# RUN DEMO
# ============================================================

using .JuliaNPC

JuliaNPC.demo()

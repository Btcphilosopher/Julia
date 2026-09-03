# Julia Fruit Machine — `fruit_machine.jl`

```julia
module FruitMachine

using Random
using Printf

# ============================================================
# CONFIGURATION
# ============================================================

const SYMBOLS = [
    :CHERRY,
    :LEMON,
    :ORANGE,
    :PLUM,
    :BELL,
    :BAR,
    :SEVEN,
]

const SYMBOL_DISPLAY = Dict(
    :CHERRY => "🍒",
    :LEMON  => "🍋",
    :ORANGE => "🍊",
    :PLUM   => "🍑",
    :BELL   => "🔔",
    :BAR    => "BAR",
    :SEVEN  => "7",
)

# Weight controls probability.
# Higher weight = more common symbol.
const SYMBOL_WEIGHTS = Dict(
    :CHERRY => 30,
    :LEMON  => 25,
    :ORANGE => 20,
    :PLUM   => 15,
    :BELL   => 8,
    :BAR    => 5,
    :SEVEN  => 2,
)

# Three-of-a-kind payout multipliers.
const PAYTABLE = Dict(
    :CHERRY => 5,
    :LEMON  => 8,
    :ORANGE => 10,
    :PLUM   => 15,
    :BELL   => 25,
    :BAR    => 50,
    :SEVEN  => 100,
)

# ============================================================
# DATA STRUCTURES
# ============================================================

mutable struct Machine
    credits::Int
    bet::Int

    reels::Vector{Vector{Symbol}}

    total_spins::Int
    total_wagered::Int
    total_paid::Int

    rng::AbstractRNG
end


struct SpinResult
    symbols::Vector{Symbol}
    wager::Int
    payout::Int
    win::Bool
    multiplier::Int
end


# ============================================================
# MACHINE CONSTRUCTION
# ============================================================

function create_reel()
    reel = Symbol[]

    for symbol in SYMBOLS
        weight = SYMBOL_WEIGHTS[symbol]

        for _ in 1:weight
            push!(reel, symbol)
        end
    end

    shuffle!(reel)

    return reel
end


function create_machine(
    ;
    credits::Int = 100,
    bet::Int = 1,
    seed::Union{Nothing,Int} = nothing,
)

    rng = seed === nothing ?
        Random.default_rng() :
        MersenneTwister(seed)

    reels = [
        create_reel(),
        create_reel(),
        create_reel(),
    ]

    return Machine(
        credits,
        bet,
        reels,
        0,
        0,
        0,
        rng,
    )
end


# ============================================================
# RANDOM REEL SELECTION
# ============================================================

function spin_reel(
    machine::Machine,
    reel::Vector{Symbol},
)

    index = rand(
        machine.rng,
        1:length(reel),
    )

    return reel[index]
end


function spin(machine::Machine)

    if machine.bet <= 0
        error("Bet must be greater than zero.")
    end

    if machine.credits < machine.bet
        error("Not enough credits.")
    end

    machine.credits -= machine.bet

    machine.total_spins += 1
    machine.total_wagered += machine.bet

    symbols = Symbol[
        spin_reel(machine, machine.reels[1]),
        spin_reel(machine, machine.reels[2]),
        spin_reel(machine, machine.reels[3]),
    ]

    payout, multiplier = calculate_payout(
        symbols,
        machine.bet,
    )

    machine.credits += payout
    machine.total_paid += payout

    return SpinResult(
        symbols,
        machine.bet,
        payout,
        payout > 0,
        multiplier,
    )
end


# ============================================================
# PAYOUT ENGINE
# ============================================================

function calculate_payout(
    symbols::Vector{Symbol},
    bet::Int,
)

    if length(symbols) != 3
        return 0, 0
    end

    # Jackpot
    if symbols[1] == :SEVEN &&
       symbols[2] == :SEVEN &&
       symbols[3] == :SEVEN

        return bet * PAYTABLE[:SEVEN], PAYTABLE[:SEVEN]
    end

    # Three matching symbols
    if symbols[1] == symbols[2] &&
       symbols[2] == symbols[3]

        symbol = symbols[1]
        multiplier = PAYTABLE[symbol]

        return bet * multiplier, multiplier
    end

    # Two cherries
    if count(==( :CHERRY), symbols) >= 2
        return bet * 2, 2
    end

    return 0, 0
end


# ============================================================
# DISPLAY
# ============================================================

function display_symbol(symbol::Symbol)

    return get(
        SYMBOL_DISPLAY,
        symbol,
        string(symbol),
    )
end


function display_result(result::SpinResult)

    println()
    println("┌─────────────────────────────┐")
    println("│          RESULT             │")
    println("├─────────────────────────────┤")

    print("│       ")

    for symbol in result.symbols
        print(
            "[ ",
            display_symbol(symbol),
            " ] "
        )
    end

    println("│")

    println("├─────────────────────────────┤")

    if result.win
        @printf(
            "│ WIN!  ×%-3d                 │\n",
            result.multiplier,
        )

        @printf(
            "│ PAYOUT: %-18d │\n",
            result.payout,
        )
    else
        println("│ No win this spin.            │")
    end

    println("└─────────────────────────────┘")
    println()
end


# ============================================================
# MACHINE STATISTICS
# ============================================================

function display_stats(machine::Machine)

    println()
    println("========== STATISTICS ==========")

    println(
        "Spins:        ",
        machine.total_spins,
    )

    println(
        "Wagered:      ",
        machine.total_wagered,
    )

    println(
        "Paid:         ",
        machine.total_paid,
    )

    if machine.total_wagered > 0

        rtp =
            machine.total_paid /
            machine.total_wagered

        @printf(
            "Observed RTP: %.2f%%\n",
            rtp * 100,
        )
    end

    println(
        "Credits:      ",
        machine.credits,
    )

    println("================================")
    println()
end


# ============================================================
# BET MANAGEMENT
# ============================================================

function set_bet!(
    machine::Machine,
    amount::Int,
)

    if amount < 1
        error("Bet must be at least 1 credit.")
    end

    machine.bet = amount

    return machine.bet
end


function add_credits!(
    machine::Machine,
    amount::Int,
)

    if amount <= 0
        error("Credit amount must be positive.")
    end

    machine.credits += amount

    return machine.credits
end


# ============================================================
# HELP
# ============================================================

function display_paytable()

    println()
    println("============= PAYTABLE =============")

    for symbol in SYMBOLS

        multiplier = PAYTABLE[symbol]

        println(
            rpad(string(display_symbol(symbol)), 10),
            "  ",
            multiplier,
            "x bet",
        )
    end

    println()
    println("Two cherries: 2x bet")
    println("=====================================")
    println()
end


function display_help()

    println("""
Commands:

  s / spin       Spin the machine
  b              Change bet
  a              Add credits
  p              Show paytable
  t              Show statistics
  h              Show help
  q              Quit

""")

end


# ============================================================
# TERMINAL GAME
# ============================================================

function game_loop!(machine::Machine)

    println()
    println("╔══════════════════════════════════╗")
    println("║        JULIA FRUIT MACHINE       ║")
    println("╚══════════════════════════════════╝")

    println()
    println("Credits: ", machine.credits)
    println("Bet:     ", machine.bet)

    display_help()

    while true

        print("> ")

        command = lowercase(
            strip(readline()),
        )

        if command == "s" ||
           command == "spin"

            try

                result = spin(machine)

                display_result(result)

                println(
                    "Credits: ",
                    machine.credits,
                )

            catch error

                println(
                    "ERROR: ",
                    error,
                )
            end

        elseif command == "b"

            print("New bet: ")

            input = strip(readline())

            try

                amount = parse(Int, input)

                set_bet!(
                    machine,
                    amount,
                )

                println(
                    "Bet set to ",
                    machine.bet,
                )

            catch

                println("Invalid bet.")
            end

        elseif command == "a"

            print("Credits to add: ")

            input = strip(readline())

            try

                amount = parse(Int, input)

                add_credits!(
                    machine,
                    amount,
                )

                println(
                    "Credits: ",
                    machine.credits,
                )

            catch

                println("Invalid amount.")
            end

        elseif command == "p"

            display_paytable()

        elseif command == "t"

            display_stats(machine)

        elseif command == "h"

            display_help()

        elseif command == "q" ||
               command == "quit"

            println()
            println("Thanks for playing.")
            break

        elseif isempty(command)

            continue

        else

            println(
                "Unknown command. Type 'h' for help."
            )
        end
    end
end


# ============================================================
# PUBLIC ENTRY POINT
# ============================================================

function main()

    machine = create_machine(
        credits = 100,
        bet = 1,
    )

    game_loop!(machine)

end


end # module


# ============================================================
# RUN
# ============================================================

using .FruitMachine

FruitMachine.main()
```


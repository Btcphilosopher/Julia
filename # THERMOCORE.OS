# THERMOCORE.OS

## Incineration & Heat-Recovery Optimisation Engine

### Pure Julia

```julia
module ThermoCoreOS

using Dates
using Printf
using Statistics


# ============================================================
# THERMOCORE.OS
# ============================================================
#
# Industrial thermal-process digital twin
#
# OBJECTIVES
#
#   • Maximise useful heat recovery
#   • Optimise heat-transfer surfaces
#   • Minimise thermal losses
#   • Maintain stable furnace conditions
#   • Monitor fouling
#   • Balance gas flow
#   • Track thermal efficiency
#   • Detect abnormal thermal behaviour
#   • Optimise heat-exchanger performance
#
# This is a simulation/optimisation framework.
# Real incinerators require certified combustion, emissions,
# pressure, safety and control systems.
#
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum PlantState begin
    OFF
    STARTUP
    STABLE
    OPTIMISING
    DERATE
    FAULT
    EMERGENCY_STOP
end


@enum HeatExchangerType begin
    WATER_WALL
    ECONOMISER
    SUPERHEATER
    AIR_PREHEATER
    CONDENSER
end


# ============================================================
# PROCESS FEED
# ============================================================

struct WasteFeed

    mass_flow_kg_s::Float64

    moisture_fraction::Float64

    combustible_fraction::Float64

    ash_fraction::Float64

    lower_heating_value_mj_kg::Float64

end


function WasteFeed(;

    mass_flow_kg_s=2.0,

    moisture_fraction=0.30,

    combustible_fraction=0.55,

    ash_fraction=0.15,

    lower_heating_value_mj_kg=8.0

)

    WasteFeed(

        mass_flow_kg_s,

        moisture_fraction,

        combustible_fraction,

        ash_fraction,

        lower_heating_value_mj_kg

    )

end


# ============================================================
# THERMAL SENSORS
# ============================================================

mutable struct ThermalSensors

    furnace_temperature_c::Float64

    gas_temperature_in_c::Float64

    gas_temperature_out_c::Float64

    steam_temperature_c::Float64

    feedwater_temperature_c::Float64

    ambient_temperature_c::Float64

    wall_temperature_c::Float64

    exhaust_temperature_c::Float64

    gas_flow_kg_s::Float64

    steam_flow_kg_s::Float64

    pressure_bar::Float64

    oxygen_fraction::Float64

    surface_temperature_c::Float64

end


function ThermalSensors()

    ThermalSensors(

        850.0,

        900.0,

        250.0,

        300.0,

        100.0,

        20.0,

        400.0,

        250.0,

        10.0,

        2.0,

        1.05,

        0.08,

        500.0

    )

end


# ============================================================
# HEAT EXCHANGER
# ============================================================

mutable struct HeatExchanger

    name::String

    exchanger_type::HeatExchangerType

    area_m2::Float64

    overall_u_w_m2k::Float64

    fouling_factor::Float64

    effectiveness::Float64

    hot_in_c::Float64

    hot_out_c::Float64

    cold_in_c::Float64

    cold_out_c::Float64

    heat_transfer_kw::Float64

    pressure_drop_bar::Float64

end


function HeatExchanger(

    name::String,

    exchanger_type::HeatExchangerType,

    area_m2::Float64,

    u_value::Float64

)

    HeatExchanger(

        name,

        exchanger_type,

        area_m2,

        u_value,

        0.0,

        0.75,

        800.0,
        300.0,

        100.0,
        250.0,

        0.0,

        0.05

    )

end


# ============================================================
# HEAT TRANSFER
# ============================================================

function lmtd(

    hot_in::Float64,

    hot_out::Float64,

    cold_in::Float64,

    cold_out::Float64

)

    ΔT1 = hot_in - cold_out
    ΔT2 = hot_out - cold_in


    if ΔT1 <= 0 || ΔT2 <= 0

        return 0.0

    end


    if abs(ΔT1 - ΔT2) < 1e-9

        return ΔT1

    end


    return (

        ΔT1 - ΔT2

    ) /

    log(

        ΔT1 / ΔT2

    )

end


function calculate_heat_transfer!(

    hx::HeatExchanger

)

    effective_u =

        hx.overall_u_w_m2k *

        (

            1.0 -
            hx.fouling_factor

        )


    ΔTlm =

        lmtd(

            hx.hot_in_c,

            hx.hot_out_c,

            hx.cold_in_c,

            hx.cold_out_c

        )


    hx.heat_transfer_kw =

        effective_u *

        hx.area_m2 *

        ΔTlm /

        1000.0 *

        hx.effectiveness


    hx.heat_transfer_kw =

        max(

            hx.heat_transfer_kw,

            0.0

        )


    return hx.heat_transfer_kw

end


# ============================================================
# COMBUSTION ENERGY MODEL
# ============================================================

function chemical_energy_input(

    feed::WasteFeed

)

    return (

        feed.mass_flow_kg_s *

        feed.lower_heating_value_mj_kg

    ) * 1000.0

end


function moisture_energy_penalty(

    feed::WasteFeed

)

    latent_heat =

        2.26


    sensible_heat =

        0.08


    return (

        feed.mass_flow_kg_s *

        feed.moisture_fraction *

        (

            latent_heat +
            sensible_heat

        )

    ) * 1000.0

end


# ============================================================
# FURNACE MODEL
# ============================================================

mutable struct Furnace

    volume_m3::Float64

    thermal_loss_fraction::Float64

    combustion_efficiency::Float64

    radiation_loss_kw::Float64

    wall_loss_kw::Float64

    useful_heat_kw::Float64

    released_heat_kw::Float64

end


function Furnace()

    Furnace(

        100.0,

        0.08,

        0.95,

        0.0,

        0.0,

        0.0,

        0.0

    )

end


function calculate_furnace_energy!(

    furnace::Furnace,

    feed::WasteFeed,

    sensors::ThermalSensors

)

    input_kw =

        chemical_energy_input(

            feed

        )


    moisture_penalty =

        moisture_energy_penalty(

            feed

        )


    furnace.released_heat_kw =

        max(

            (

                input_kw -

                moisture_penalty

            ) *

            furnace.combustion_efficiency,

            0.0

        )


    furnace.radiation_loss_kw =

        furnace.released_heat_kw *

        0.035


    furnace.wall_loss_kw =

        furnace.released_heat_kw *

        furnace.thermal_loss_fraction


    furnace.useful_heat_kw =

        max(

            furnace.released_heat_kw -

            furnace.radiation_loss_kw -

            furnace.wall_loss_kw,

            0.0

        )


end


# ============================================================
# FOULING MODEL
# ============================================================

mutable struct FoulingModel

    deposition_rate::Float64

    fouling_rate::Float64

    cleaning_threshold::Float64

    cleaning_required::Bool

end


FoulingModel() =

    FoulingModel(

        0.0,

        0.00001,

        0.70,

        false

    )


function update_fouling!(

    fouling::FoulingModel,

    hx::HeatExchanger,

    gas_temperature::Float64,

    dt::Float64

)

    thermal_factor =

        clamp(

            (

                gas_temperature -
                400.0

            ) / 700.0,

            0.0,
            1.0

        )


    fouling.deposition_rate =

        fouling.fouling_rate *

        thermal_factor


    hx.fouling_factor +=

        fouling.deposition_rate *
        dt


    hx.fouling_factor =

        clamp(

            hx.fouling_factor,

            0.0,
            0.95

        )


    fouling.cleaning_required =

        hx.fouling_factor >=

        fouling.cleaning_threshold

end


# ============================================================
# HEAT-RECOVERY NETWORK
# ============================================================

mutable struct HeatRecoveryNetwork

    exchangers::Vector{HeatExchanger}

    total_recovered_kw::Float64

    recovery_efficiency::Float64

end


function HeatRecoveryNetwork()

    exchangers = [

        HeatExchanger(

            "WATER WALL",

            WATER_WALL,

            300.0,

            45.0

        ),

        HeatExchanger(

            "ECONOMISER",

            ECONOMISER,

            180.0,

            80.0

        ),

        HeatExchanger(

            "SUPERHEATER",

            SUPERHEATER,

            140.0,

            65.0

        ),

        HeatExchanger(

            "AIR PREHEATER",

            AIR_PREHEATER,

            100.0,

            40.0

        )

    ]


    HeatRecoveryNetwork(

        exchangers,

        0.0,

        0.0

    )

end


function calculate_recovery!(

    network::HeatRecoveryNetwork,

    furnace::Furnace

)

    total = 0.0


    for hx in network.exchangers

        total +=

            calculate_heat_transfer!(

                hx

            )

    end


    network.total_recovered_kw =

        min(

            total,

            furnace.useful_heat_kw

        )


    network.recovery_efficiency =

        network.total_recovered_kw /

        max(

            furnace.released_heat_kw,

            1.0

        )

end


# ============================================================
# STEAM SYSTEM
# ============================================================

mutable struct SteamSystem

    steam_energy_kw::Float64

    turbine_efficiency::Float64

    electrical_output_kw::Float64

    thermal_export_kw::Float64

end


SteamSystem() =

    SteamSystem(

        0.0,

        0.32,

        0.0,

        0.0

    )


function calculate_steam_output!(

    steam::SteamSystem,

    recovered_heat_kw::Float64

)

    steam.steam_energy_kw =

        recovered_heat_kw


    steam.electrical_output_kw =

        recovered_heat_kw *

        steam.turbine_efficiency


    steam.thermal_export_kw =

        recovered_heat_kw *

        0.45

end


# ============================================================
# PLANT OPTIMISER
# ============================================================

struct OptimisationResult

    furnace_efficiency::Float64

    heat_recovery_efficiency::Float64

    useful_heat_kw::Float64

    recovered_heat_kw::Float64

    electrical_output_kw::Float64

    exhaust_temperature_c::Float64

    fouling_penalty::Float64

    score::Float64

end


function optimisation_score(

    furnace_efficiency,

    heat_recovery,

    electrical_output,

    exhaust_temperature,

    fouling_penalty

)

    efficiency_score =

        furnace_efficiency * 400.0


    recovery_score =

        heat_recovery * 400.0


    power_score =

        electrical_output / 100.0


    exhaust_penalty =

        max(

            exhaust_temperature - 180.0,

            0.0

        ) * 0.5


    fouling_penalty_score =

        fouling_penalty * 100.0


    return (

        efficiency_score +

        recovery_score +

        power_score -

        exhaust_penalty -

        fouling_penalty_score

    )

end


# ============================================================
# PLANT
# ============================================================

mutable struct ThermalPlant

    name::String

    state::PlantState

    feed::WasteFeed

    sensors::ThermalSensors

    furnace::Furnace

    network::HeatRecoveryNetwork

    steam::SteamSystem

    fouling::FoulingModel

    elapsed_s::Float64

    telemetry::Vector{NamedTuple}

end


function ThermalPlant(

    name="THERMOCORE-001"

)

    ThermalPlant(

        name,

        OFF,

        WasteFeed(),

        ThermalSensors(),

        Furnace(),

        HeatRecoveryNetwork(),

        SteamSystem(),

        FoulingModel(),

        0.0,

        NamedTuple[]

    )

end


# ============================================================
# PLANT START
# ============================================================

function start!(

    plant::ThermalPlant

)

    plant.state =

        STARTUP

end


# ============================================================
# PROCESS SIMULATION
# ============================================================

function simulate_step!(

    plant::ThermalPlant,

    dt::Float64

)

    plant.elapsed_s += dt


    if plant.state == STARTUP

        if plant.sensors.furnace_temperature_c >= 700.0

            plant.state = STABLE

        end

    end


    # --------------------------------------------------------
    # ENERGY GENERATION
    # --------------------------------------------------------

    calculate_furnace_energy!(

        plant.furnace,

        plant.feed,

        plant.sensors

    )


    # --------------------------------------------------------
    # HEAT RECOVERY
    # --------------------------------------------------------

    for hx in plant.network.exchangers

        update_fouling!(

            plant.fouling,

            hx,

            plant.sensors.gas_temperature_in_c,

            dt

        )

    end


    calculate_recovery!(

        plant.network,

        plant.furnace

    )


    # --------------------------------------------------------
    # STEAM / POWER
    # --------------------------------------------------------

    calculate_steam_output!(

        plant.steam,

        plant.network.total_recovered_kw

    )


    # --------------------------------------------------------
    # EXHAUST
    # --------------------------------------------------------

    recovered_fraction =

        plant.network.recovery_efficiency


    plant.sensors.exhaust_temperature_c =

        max(

            150.0,

            plant.sensors.gas_temperature_in_c *

            (

                1.0 -
                recovered_fraction

            )

        )


    # --------------------------------------------------------
    # TELEMETRY
    # --------------------------------------------------------

    push!(

        plant.telemetry,

        (

            timestamp=now(),

            state=plant.state,

            furnace_temperature=

                plant.sensors.furnace_temperature_c,

            recovered_heat_kw=

                plant.network.total_recovered_kw,

            electrical_output_kw=

                plant.steam.electrical_output_kw,

            exhaust_temperature=

                plant.sensors.exhaust_temperature_c,

            recovery_efficiency=

                plant.network.recovery_efficiency

        )

    )

end


# ============================================================
# HEAT-TRANSFER OPTIMISER
# ============================================================

function optimise_heat_transfer(

    plant::ThermalPlant

)

    best_score = -Inf

    best_result = nothing


    original_area =

        [

            hx.area_m2

            for hx in plant.network.exchangers

        ]


    # Explore exchanger-area allocations.

    for multiplier in

        0.70:0.05:1.50


        for hx in plant.network.exchangers

            hx.area_m2 =

                original_area[

                    findfirst(

                        x -> x === hx,

                        plant.network.exchangers

                    )

                ] * multiplier

        end


        calculate_furnace_energy!(

            plant.furnace,

            plant.feed,

            plant.sensors

        )


        calculate_recovery!(

            plant.network,

            plant.furnace

        )


        calculate_steam_output!(

            plant.steam,

            plant.network.total_recovered_kw

        )


        exhaust =

            max(

                150.0,

                plant.sensors.gas_temperature_in_c *

                (

                    1.0 -
                    plant.network.recovery_efficiency

                )

            )


        fouling =

            mean(

                hx.fouling_factor

                for hx in

                plant.network.exchangers

            )


        score =

            optimisation_score(

                plant.furnace.combustion_efficiency,

                plant.network.recovery_efficiency,

                plant.steam.electrical_output_kw,

                exhaust,

                fouling

            )


        if score > best_score

            best_score = score


            best_result =

                OptimisationResult(

                    plant.furnace.combustion_efficiency,

                    plant.network.recovery_efficiency,

                    plant.furnace.useful_heat_kw,

                    plant.network.total_recovered_kw,

                    plant.steam.electrical_output_kw,

                    exhaust,

                    fouling,

                    score

                )

        end

    end


    # Restore original configuration.

    for (hx, area) in

        zip(

            plant.network.exchangers,

            original_area

        )

        hx.area_m2 = area

    end


    return best_result

end


# ============================================================
# PERFORMANCE REPORT
# ============================================================

function report(

    plant::ThermalPlant

)

    println()

    println("="^90)

    println(

        "                     THERMOCORE.OS"

    )

    println(

        "              THERMAL RECOVERY DASHBOARD"

    )

    println("="^90)

    println()

    println(

        "PLANT               : ",

        plant.name

    )

    println(

        "STATE               : ",

        plant.state

    )

    println()

    println(

        @sprintf(

            "FURNACE TEMP        : %8.1f °C",

            plant.sensors.furnace_temperature_c

        )

    )

    println(

        @sprintf(

            "INPUT ENERGY        : %8.1f kW",

            chemical_energy_input(

                plant.feed

            )

        )

    )

    println(

        @sprintf(

            "RELEASED HEAT       : %8.1f kW",

            plant.furnace.released_heat_kw

        )

    )

    println(

        @sprintf(

            "RECOVERED HEAT      : %8.1f kW",

            plant.network.total_recovered_kw

        )

    )

    println(

        @sprintf(

            "RECOVERY EFFICIENCY : %8.2f %%",

            plant.network.recovery_efficiency * 100

        )

    )

    println(

        @sprintf(

            "ELECTRICAL OUTPUT   : %8.1f kW",

            plant.steam.electrical_output_kw

        )

    )

    println(

        @sprintf(

            "THERMAL EXPORT      : %8.1f kW",

            plant.steam.thermal_export_kw

        )

    )

    println(

        @sprintf(

            "EXHAUST TEMP        : %8.1f °C",

            plant.sensors.exhaust_temperature_c

        )

    )

    println()

    println(

        "HEAT EXCHANGERS"

    )

    println(

        "-"^90

    )


    for hx in plant.network.exchangers

        println(

            @sprintf(

                "%-18s AREA %7.1f m² | U %7.1f | FOULING %6.2f | HEAT %8.1f kW",

                hx.name,

                hx.area_m2,

                hx.overall_u_w_m2k,

                hx.fouling_factor,

                hx.heat_transfer_kw

            )

        )

    end


    println()

    println("="^90)

end


# ============================================================
# OPTIMISATION REPORT
# ============================================================

function optimisation_report(

    plant::ThermalPlant

)

    result =

        optimise_heat_transfer(

            plant

        )


    println()

    println("="^90)

    println(

        "                  HEAT-TRANSFER OPTIMISER"

    )

    println("="^90)

    println()

    println(

        @sprintf(

            "Combustion efficiency       : %.2f %%",

            result.furnace_efficiency * 100

        )

    )

    println(

        @sprintf(

            "Heat recovery efficiency    : %.2f %%",

            result.heat_recovery_efficiency * 100

        )

    )

    println(

        @sprintf(

            "Useful furnace heat        : %.1f kW",

            result.useful_heat_kw

        )

    )

    println(

        @sprintf(

            "Recovered heat             : %.1f kW",

            result.recovered_heat_kw

        )

    )

    println(

        @sprintf(

            "Electrical output          : %.1f kW",

            result.electrical_output_kw

        )

    )

    println(

        @sprintf(

            "Predicted exhaust          : %.1f °C",

            result.exhaust_temperature_c

        )

    )

    println(

        @sprintf(

            "Fouling penalty            : %.4f",

            result.fouling_penalty

        )

    )

    println(

        @sprintf(

            "Optimisation score         : %.2f",

            result.score

        )

    )

    println()

    println("="^90)

end


# ============================================================
# DIGITAL-TWIN DEMO
# ============================================================

function simulate()

    plant =

        ThermalPlant(

            "THERMOCORE-LAB-001"

        )


    println()

    println(

        "BOOTING THERMOCORE.OS..."

    )


    start!(

        plant

    )


    println(

        "DIGITAL TWIN ONLINE."

    )


    # Run simulated process.

    for tick in 1:3600

        simulate_step!(

            plant,

            1.0

        )


        if tick % 600 == 0

            report(

                plant

            )

        end

    end


    optimisation_report(

        plant

    )

end


# ============================================================
# EXPORTS
# ============================================================

export ThermalPlant
export WasteFeed
export HeatExchanger
export HeatRecoveryNetwork

export start!
export simulate_step!
export optimise_heat_transfer
export report
export optimisation_report
export simulate

end


# ============================================================
# PROGRAM ENTRY
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .ThermoCoreOS

    ThermoCoreOS.simulate()

end
```


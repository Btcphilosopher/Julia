# ================================================================
# MusaBreed.jl
#
# Banana / Musa breeding-program optimisation engine
#
# Research-oriented computational framework
#
# Models:
#   - germplasm
#   - pedigrees
#   - genotypes
#   - phenotypes
#   - breeding values
#   - disease resistance
#   - yield
#   - drought tolerance
#   - fruit quality
#   - parent selection
#   - cross optimisation
#   - genomic selection
# ================================================================

using Random
using Statistics
using LinearAlgebra
using Printf


# ================================================================
# 1. TRAITS
# ================================================================

@enum Trait begin

    YIELD
    BLACK_SIGATOKA_RESISTANCE
    FUSARIUM_TR4_RESISTANCE
    DROUGHT_TOLERANCE
    PLANT_HEIGHT
    MATURITY_TIME
    FRUIT_SIZE
    FRUIT_QUALITY
    PROVITAMIN_A
    PEST_RESISTANCE

end


# ================================================================
# 2. BANANA GENOTYPE
# ================================================================

mutable struct Banana

    id::Int

    name::String

    ploidy::Int

    genome_group::String

    parent1::Union{Nothing,Int}
    parent2::Union{Nothing,Int}

    markers::Vector{Float64}

    breeding_values::Dict{Trait,Float64}

    phenotype::Dict{Trait,Float64}

    generation::Int

end


# ================================================================
# 3. BREEDING PROGRAM
# ================================================================

mutable struct BreedingProgram

    population::Vector{Banana}

    marker_effects::Dict{Trait,Vector{Float64}}

    target_weights::Dict{Trait,Float64}

    generation::Int

end


# ================================================================
# 4. CREATE BANANA
# ================================================================

function create_banana(

    id,
    name,
    ploidy,
    genome_group,
    marker_count

)

    markers =
        randn(marker_count)


    breeding_values =
        Dict(
            trait => randn()
            for trait in instances(Trait)
        )


    phenotype =
        Dict(
            trait => 0.0
            for trait in instances(Trait)
        )


    return Banana(

        id,
        name,
        ploidy,
        genome_group,

        nothing,
        nothing,

        markers,

        breeding_values,

        phenotype,

        0
    )

end


# ================================================================
# 5. GENOMIC KERNEL
#
# Converts marker matrix into genomic relationship matrix.
# ================================================================

function genomic_relationship_matrix(

    population

)

    n =
        length(population)


    m =
        length(
            population[1].markers
        )


    M =
        zeros(n,m)


    for i in 1:n

        M[i,:] =
            population[i].markers

    end


    # Standardise markers

    for j in 1:m

        μ =
            mean(
                M[:,j]
            )

        σ =
            std(
                M[:,j]
            )


        if σ > 0

            M[:,j] =
                (
                    M[:,j] .- μ
                ) ./ σ

        end

    end


    G =
        (
            M *
            transpose(M)
        ) /
        m


    return G

end


# ================================================================
# 6. GENOMIC BREEDING VALUE
# ================================================================

function genomic_breeding_value(

    banana::Banana,

    effects::Vector{Float64}

)

    return dot(

        banana.markers,

        effects

    )

end


# ================================================================
# 7. PHENOTYPE SIMULATOR
#
# Phenotype = genetic value + environmental noise
# ================================================================

function simulate_phenotype!(

    banana::Banana,

    trait::Trait;

    environmental_sd=0.25

)

    genetic =
        banana.breeding_values[
            trait
        ]


    environment =
        environmental_sd *
        randn()


    banana.phenotype[
        trait
    ] =
        genetic +
        environment


    return banana.phenotype[
        trait
    ]

end


# ================================================================
# 8. GENOMIC PREDICTION
# ================================================================

function predict_GEBV(

    banana,

    marker_effects

)

    predictions =
        Dict{Trait,Float64}()


    for trait in
        instances(Trait)

        effects =
            marker_effects[
                trait
            ]


        predictions[trait] =
            genomic_breeding_value(
                banana,
                effects
            )

    end


    return predictions

end


# ================================================================
# 9. BREEDING INDEX
#
# Combines multiple traits into one selection score.
# ================================================================

function breeding_index(

    banana::Banana,

    program::BreedingProgram

)

    score =
        0.0


    for trait in
        instances(Trait)

        weight =
            get(
                program.target_weights,
                trait,
                0.0
            )


        value =
            get(
                banana.breeding_values,
                trait,
                0.0
            )


        score +=
            weight *
            value

    end


    return score

end


# ================================================================
# 10. DISEASE RESISTANCE INDEX
# ================================================================

function disease_index(

    banana

)

    sigatoka =
        banana.breeding_values[
            BLACK_SIGATOKA_RESISTANCE
        ]


    tr4 =
        banana.breeding_values[
            FUSARIUM_TR4_RESISTANCE
        ]


    pest =
        banana.breeding_values[
            PEST_RESISTANCE
        ]


    return (

        0.40 * sigatoka +

        0.40 * tr4 +

        0.20 * pest

    )

end


# ================================================================
# 11. CROSS SIMULATION
#
# Simplified quantitative-genetic model.
# ================================================================

function make_cross(

    parent1::Banana,
    parent2::Banana,

    child_id::Int;

    mutation_sd=0.03

)

    marker_count =
        length(
            parent1.markers
        )


    child_markers =
        zeros(marker_count)


    for i in
        1:marker_count

        p =
            rand() < 0.5 ?
            parent1.markers[i] :
            parent2.markers[i]


        q =
            rand() < 0.5 ?
            parent2.markers[i] :
            parent1.markers[i]


        child_markers[i] =
            (
                p + q
            ) / 2 +
            mutation_sd *
            randn()

    end


    breeding_values =
        Dict{Trait,Float64}()


    for trait in
        instances(Trait)

        p1 =
            parent1.breeding_values[
                trait
            ]


        p2 =
            parent2.breeding_values[
                trait
            ]


        # Additive inheritance + segregation

        breeding_values[trait] =

            0.5 * p1 +

            0.5 * p2 +

            0.20 *
            randn()

    end


    phenotype =
        Dict(
            trait => 0.0
            for trait in instances(Trait)
        )


    return Banana(

        child_id,

        "HYBRID_$child_id",

        max(
            parent1.ploidy,
            parent2.ploidy
        ),

        parent1.genome_group,

        parent1.id,
        parent2.id,

        child_markers,

        breeding_values,

        phenotype,

        max(
            parent1.generation,
            parent2.generation
        ) + 1

    )

end


# ================================================================
# 12. CROSS PREDICTION
#
# Predict expected offspring before making the cross.
# ================================================================

function predicted_cross_value(

    parent1,
    parent2,
    program

)

    score =
        0.0


    for trait in
        instances(Trait)

        weight =
            get(
                program.target_weights,
                trait,
                0.0
            )


        expected =

            0.5 *
            parent1.breeding_values[
                trait
            ] +

            0.5 *
            parent2.breeding_values[
                trait
            ]


        score +=
            weight *
            expected

    end


    return score

end


# ================================================================
# 13. CROSS DIVERSITY
# ================================================================

function genetic_distance(

    a,
    b

)

    return norm(

        a.markers -
        b.markers

    )

end


# ================================================================
# 14. CROSS SCORE
#
# Balances:
#
#   desired traits
#   disease resistance
#   genetic diversity
#
# ================================================================

function cross_score(

    parent1,
    parent2,
    program;

    diversity_weight=0.25

)

    expected =
        predicted_cross_value(
            parent1,
            parent2,
            program
        )


    diversity =
        genetic_distance(
            parent1,
            parent2
        )


    return (

        expected +

        diversity_weight *
        diversity

    )

end


# ================================================================
# 15. FIND BEST PARENTS
# ================================================================

function optimise_crosses(

    program::BreedingProgram;

    top_n=20

)

    candidates = []


    population =
        program.population


    for i in
        1:length(population)

        for j in
            i+1:length(population)

            a =
                population[i]

            b =
                population[j]


            score =
                cross_score(
                    a,
                    b,
                    program
                )


            push!(
                candidates,
                (
                    parent1=a.id,
                    parent2=b.id,
                    score=score
                )
            )

        end

    end


    sort!(
        candidates,
        by=x -> x.score,
        rev=true
    )


    return candidates[
        1:min(
            top_n,
            length(candidates)
        )
    ]

end


# ================================================================
# 16. GENERATIONAL SELECTION
# ================================================================

function select_best(

    population,

    program;

    fraction=0.10

)

    ranked = sort(

        population,

        by=x ->
            breeding_index(
                x,
                program
            ),

        rev=true

    )


    n =
        max(
            1,
            round(
                Int,
                length(population) *
                fraction
            )
        )


    return ranked[
        1:n
    ]

end


# ================================================================
# 17. GENETIC GAIN
# ================================================================

function genetic_gain(

    old_population,

    new_population,

    trait

)

    old_mean =
        mean(
            x.breeding_values[
                trait
            ]
            for x in old_population
        )


    new_mean =
        mean(
            x.breeding_values[
                trait
            ]
            for x in new_population
        )


    return (
        new_mean -
        old_mean
    )

end


# ================================================================
# 18. BREEDING PROGRAM SIMULATION
# ================================================================

function run_generation!(

    program::BreedingProgram;

    offspring_per_cross=20

)

    parents =
        select_best(
            program.population,
            program
        )


    crosses =
        optimise_crosses(
            program,
            top_n=10
        )


    next_population =
        Banana[]


    next_id =
        maximum(
            x.id
            for x in program.population
        ) + 1


    for cross in crosses

        p1 =
            program.population[
                findfirst(
                    x -> x.id ==
                    cross.parent1,
                    program.population
                )
            ]


        p2 =
            program.population[
                findfirst(
                    x -> x.id ==
                    cross.parent2,
                    program.population
                )
            ]


        for k in
            1:offspring_per_cross

            child =
                make_cross(
                    p1,
                    p2,
                    next_id
                )


            push!(
                next_population,
                child
            )


            next_id += 1

        end

    end


    program.population =
        next_population


    program.generation +=
        1


    return program

end


# ================================================================
# 19. BREEDING REPORT
# ================================================================

function breeding_report(

    program

)

    println()
    println(
        "============================================================"
    )

    println(
        "                    MusaBreed.jl"
    )

    println(
        "============================================================"
    )


    @printf(
        "Generation:             %d\n",
        program.generation
    )


    @printf(
        "Population:             %d\n",
        length(
            program.population
        )
    )


    for trait in
        instances(Trait)

        values =
            [
                x.breeding_values[
                    trait
                ]
                for x in
                program.population
            ]


        @printf(
            "%-28s mean=%8.3f  max=%8.3f\n",

            string(trait),

            mean(values),

            maximum(values)
        )

    end

    println(
        "============================================================"
    )

end


# ================================================================
# 20. INITIAL PROGRAMME
# ================================================================

Random.seed!(42)


marker_count =
    2_000


population =
    Banana[]


for i in 1:200

    push!(
        population,

        create_banana(

            i,

            "MUSA_$i",

            rand([
                2,
                3,
                4
            ]),

            rand([
                "AA",
                "AAA",
                "AAB",
                "ABB"
            ]),

            marker_count

        )
    )

end


# ================================================================
# 21. BREEDING TARGETS
# ================================================================

targets =
    Dict(

        YIELD => 0.30,

        BLACK_SIGATOKA_RESISTANCE => 0.20,

        FUSARIUM_TR4_RESISTANCE => 0.20,

        DROUGHT_TOLERANCE => 0.10,

        FRUIT_QUALITY => 0.10,

        PROVITAMIN_A => 0.05,

        PLANT_HEIGHT => 0.05

    )


# ================================================================
# 22. GENOMIC EFFECTS
# ================================================================

effects =
    Dict(

        trait =>

        randn(marker_count)

        for trait in
        instances(Trait)

    )


program =
    BreedingProgram(

        population,

        effects,

        targets,

        0

    )


# ================================================================
# 23. RUN
# ================================================================

breeding_report(
    program
)


println()
println(
    "OPTIMISING CROSSES..."
)


best_crosses =
    optimise_crosses(
        program,
        top_n=10
    )


for cross in
    best_crosses

    @printf(

        "Parent %d × Parent %d   score=%8.3f\n",

        cross.parent1,

        cross.parent2,

        cross.score

    )

end


println()
println(
    "RUNNING BREEDING GENERATION..."
)


run_generation!(
    program,
    offspring_per_cross=25
)


breeding_report(
    program
)

























                    MusaBreed.jl
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
       ▼                 ▼                 ▼
   GERMPLASM          GENOMICS         PHENOTYPES
       │                 │                 │
       └─────────────────┼─────────────────┘
                         ▼
                  BREEDING MODEL
                         │
             ┌───────────┼───────────┐
             ▼           ▼           ▼
           YIELD       DISEASE     QUALITY
             │           │           │
             └───────────┼───────────┘
                         ▼
                  GEBV PREDICTION
                         │
                         ▼
                  CROSS OPTIMIZER
                         │
                         ▼
              ┌────────────────────┐
              │ BEST PARENT PAIRS  │
              └─────────┬──────────┘
                        ▼
                   OFFSPRING
                        │
                        ▼
                 FIELD TRIALS
                        │
                        ▼
                   PHENOTYPING
                        │
                        ▼
                   NEW DATA
                        │
                        └──────────► MODEL UPDATE

# ============================================================
# MOULIN INDUSTRIEL DE BLÉ TENDRE
# Système de gestion et de pilotage d'une minoterie française
# Langage : Julia
# ============================================================

using Dates
using Statistics

# ============================================================
# STRUCTURES DE DONNÉES
# ============================================================

mutable struct LotBle
    id::String
    origine::String
    poids_tonnes::Float64
    humidite::Float64
    proteines::Float64
    poids_specifique::Float64
    indice_chute::Float64
    impuretes::Float64
    statut::String
end

mutable struct ProduitFarine
    nom::String
    taux_extraction::Float64
    stock_tonnes::Float64
    humidite_cible::Float64
    proteines_cible::Float64
end

mutable struct Moulin
    capacite_horaire::Float64
    rendement_global::Float64
    energie_kwh_tonne::Float64
    temperature_max::Float64
end

# ============================================================
# CONFIGURATION DU MOULIN
# ============================================================

moulin = Moulin(
    12.0,       # tonnes/heure
    0.76,       # rendement global
    68.0,       # kWh/tonne
    45.0        # température maximale
)

# ============================================================
# STOCKS DE BLÉ
# ============================================================

stocks_ble = LotBle[
    LotBle(
        "BL-2026-001",
        "Beauce, France",
        250.0,
        14.2,
        11.8,
        77.0,
        285.0,
        0.7,
        "Disponible"
    ),

    LotBle(
        "BL-2026-002",
        "Hauts-de-France",
        180.0,
        13.8,
        12.4,
        78.5,
        310.0,
        0.5,
        "Disponible"
    ),

    LotBle(
        "BL-2026-003",
        "Normandie",
        210.0,
        14.5,
        11.5,
        76.8,
        275.0,
        0.8,
        "Disponible"
    )
]

# ============================================================
# PRODUITS
# ============================================================

farines = Dict(
    "T65" => ProduitFarine(
        "Farine de blé T65",
        0.78,
        50.0,
        15.0,
        11.5
    ),

    "T55" => ProduitFarine(
        "Farine de blé T55",
        0.75,
        80.0,
        15.0,
        11.0
    ),

    "T45" => ProduitFarine(
        "Farine de blé T45",
        0.70,
        30.0,
        15.0,
        10.5
    )
)

# ============================================================
# CONTRÔLE QUALITÉ
# ============================================================

function controler_lot(lot::LotBle)

    println()
    println("============================================")
    println("CONTRÔLE QUALITÉ DU LOT ", lot.id)
    println("============================================")

    println("Origine              : ", lot.origine)
    println("Poids                 : ", lot.poids_tonnes, " tonnes")
    println("Humidité              : ", lot.humidite, " %")
    println("Protéines             : ", lot.proteines, " %")
    println("Poids spécifique      : ", lot.poids_specifique)
    println("Indice de chute       : ", lot.indice_chute, " s")
    println("Impuretés             : ", lot.impuretes, " %")

    conforme = true

    if lot.humidite > 15.0
        println("⚠ Humidité trop élevée")
        conforme = false
    end

    if lot.impuretes > 1.0
        println("⚠ Niveau d'impuretés élevé")
        conforme = false
    end

    if lot.poids_specifique < 75.0
        println("⚠ Poids spécifique insuffisant")
        conforme = false
    end

    if lot.indice_chute < 220.0
        println("⚠ Indice de chute insuffisant")
        conforme = false
    end

    if conforme
        lot.statut = "Conforme"
        println("✓ LOT CONFORME")
    else
        lot.statut = "À contrôler"
        println("✗ LOT À CONTRÔLER")
    end

    return conforme
end

# ============================================================
# NETTOYAGE DU BLÉ
# ============================================================

function nettoyer_ble(lot::LotBle)

    println()
    println("NETTOYAGE DU LOT ", lot.id)
    println("--------------------------------------------")

    masse_initiale = lot.poids_tonnes

    pertes = masse_initiale * lot.impuretes / 100
    masse_nette = masse_initiale - pertes

    lot.poids_tonnes = masse_nette

    println("Masse initiale : ", round(masse_initiale, digits=2), " t")
    println("Déchets        : ", round(pertes, digits=2), " t")
    println("Masse nette    : ", round(masse_nette, digits=2), " t")

    return masse_nette
end

# ============================================================
# CONDITIONNEMENT
# ============================================================

function conditionner_ble(lot::LotBle)

    println()
    println("CONDITIONNEMENT DU LOT")
    println("--------------------------------------------")

    humidite_cible = 16.0

    if lot.humidite < humidite_cible

        eau = lot.poids_tonnes *
              (humidite_cible - lot.humidite) / 100

        println(
            "Ajout d'eau estimé : ",
            round(eau, digits=2),
            " t"
        )

        lot.humidite = humidite_cible

    else

        println("Aucun ajout d'eau nécessaire.")
    end
end

# ============================================================
# CALCUL DU RENDEMENT
# ============================================================

function calculer_rendement(
    masse_ble::Float64,
    taux_extraction::Float64
)

    masse_far = masse_ble * taux_extraction
    issues = masse_ble - masse_far

    return masse_far, issues
end

# ============================================================
# MOUTURE
# ============================================================

function moudre(
    lot::LotBle,
    type_farine::String
)

    if !haskey(farines, type_farine)
        println("Type de farine inconnu.")
        return
    end

    farine = farines[type_farine]

    println()
    println("============================================")
    println("MOUTURE INDUSTRIELLE")
    println("============================================")

    println("Lot       : ", lot.id)
    println("Produit   : ", farine.nom)

    masse_farine, issues =
        calculer_rendement(
            lot.poids_tonnes,
            farine.taux_extraction
        )

    energie =
        lot.poids_tonnes *
        moulin.energie_kwh_tonne

    farine.stock_tonnes += masse_farine

    println()
    println(
        "Blé traité       : ",
        round(lot.poids_tonnes, digits=2),
        " t"
    )

    println(
        "Farine produite  : ",
        round(masse_farine, digits=2),
        " t"
    )

    println(
        "Issues           : ",
        round(issues, digits=2),
        " t"
    )

    println(
        "Énergie utilisée : ",
        round(energie, digits=2),
        " kWh"
    )

    println(
        "Stock ",
        type_farine,
        " : ",
        round(farine.stock_tonnes, digits=2),
        " t"
    )

    lot.statut = "Transformé"

    return masse_farine
end

# ============================================================
# PLANIFICATION DE PRODUCTION
# ============================================================

function planifier_production(
    demande_tonnes::Float64,
    type_farine::String
)

    farine = farines[type_farine]

    besoin_ble =
        demande_tonnes /
        farine.taux_extraction

    heures =
        besoin_ble /
        moulin.capacite_horaire

    println()
    println("PLAN DE PRODUCTION")
    println("--------------------------------------------")

    println("Farine demandée : ", type_farine)
    println("Quantité        : ", demande_tonnes, " t")

    println(
        "Blé nécessaire  : ",
        round(besoin_ble, digits=2),
        " t"
    )

    println(
        "Temps de mouture : ",
        round(heures, digits=2),
        " heures"
    )

    return besoin_ble, heures
end

# ============================================================
# TABLEAU DE BORD
# ============================================================

function tableau_de_bord()

    println()
    println("╔════════════════════════════════════════════╗")
    println("║       TABLEAU DE BORD — MINOTERIE         ║")
    println("╚════════════════════════════════════════════╝")

    println()
    println("Date : ", Dates.format(now(), "dd/mm/yyyy HH:MM"))

    println()
    println("CAPACITÉ")
    println("--------------------------------------------")
    println(
        "Capacité horaire : ",
        moulin.capacite_horaire,
        " t/h"
    )

    println(
        "Rendement global : ",
        moulin.rendement_global * 100,
        " %"
    )

    println(
        "Énergie moyenne  : ",
        moulin.energie_kwh_tonne,
        " kWh/t"
    )

    println()
    println("STOCKS DE BLÉ")
    println("--------------------------------------------")

    for lot in stocks_ble

        println(
            lot.id,
            " | ",
            lot.origine,
            " | ",
            round(lot.poids_tonnes, digits=1),
            " t | ",
            lot.statut
        )

    end

    println()
    println("STOCKS DE FARINE")
    println("--------------------------------------------")

    for (code, farine) in farines

        println(
            code,
            " | ",
            round(farine.stock_tonnes, digits=1),
            " t"
        )

    end

    println()
end

# ============================================================
# OPTIMISATION D'UN MÉLANGE
# ============================================================

function optimiser_melange(
    lots::Vector{LotBle},
    proteines_cible::Float64
)

    poids_total = sum(lot.poids_tonnes for lot in lots)

    proteines_moyennes =
        sum(
            lot.poids_tonnes * lot.proteines
            for lot in lots
        ) / poids_total

    println()
    println("OPTIMISATION DU MÉLANGE")
    println("--------------------------------------------")

    println(
        "Protéines actuelles : ",
        round(proteines_moyennes, digits=2),
        " %"
    )

    println(
        "Protéines souhaitées : ",
        proteines_cible,
        " %"
    )

    difference =
        proteines_cible -
        proteines_moyennes

    if difference > 0

        println(
            "Le mélange nécessite un lot plus riche en protéines."
        )

    elseif difference < 0

        println(
            "Le mélange nécessite un lot moins riche en protéines."
        )

    else

        println("Mélange déjà conforme à la cible.")

    end

    return proteines_moyennes
end

# ============================================================
# EXEMPLE DE CYCLE INDUSTRIEL
# ============================================================

println()
println("================================================")
println("      SYSTÈME DE GESTION DE MINOTERIE")
println("      BLÉ TENDRE — FRANCE")
println("================================================")

tableau_de_bord()

# Contrôle qualité
lot = stocks_ble[1]

if controler_lot(lot)

    # Nettoyage
    nettoyer_ble(lot)

    # Conditionnement
    conditionner_ble(lot)

    # Mouture en T65
    moudre(lot, "T65")

end

# Planification
planifier_production(
    100.0,
    "T65"
)

# Optimisation d'un mélange
optimiser_melange(
    stocks_ble,
    12.0
)

# État final
tableau_de_bord()

println("Système terminé.")

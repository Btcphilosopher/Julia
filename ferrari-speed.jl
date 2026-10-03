# ============================================================
# CONTROLLO VELOCITÀ SU RETTILINEO
# Sistema di controllo automobilistico
#
# Linguaggio: Julia
# Interfaccia e variabili: Italiano
# ============================================================

using Printf
using Dates

# ============================================================
# PARAMETRI DEL VEICOLO
# ============================================================

mutable struct Veicolo
    velocita::Float64          # m/s
    accelerazione::Float64     # m/s²
    posizione::Float64         # metri
    velocita_massima::Float64  # m/s
    accelerazione_massima::Float64
    frenata_massima::Float64
end

# ============================================================
# PARAMETRI DELLA STRADA
# ============================================================

struct Rettilineo
    lunghezza::Float64
    velocita_limite::Float64
end

# ============================================================
# INIZIALIZZAZIONE
# ============================================================

veicolo = Veicolo(
    0.0,       # velocità iniziale
    0.0,       # accelerazione
    0.0,       # posizione
    80.0,      # velocità massima: 80 m/s
    3.0,       # accelerazione massima
    6.0        # frenata massima
)

strada = Rettilineo(
    2000.0,    # 2 km
    30.0       # limite: 30 m/s ≈ 108 km/h
)

# ============================================================
# CONVERSIONI
# ============================================================

function ms_a_kmh(velocita::Float64)
    return velocita * 3.6
end

function kmh_a_ms(velocita::Float64)
    return velocita / 3.6
end

# ============================================================
# DISTANZA DI FRENATA
# ============================================================

function distanza_frenata(
    velocita::Float64,
    decelerazione::Float64
)

    if decelerazione <= 0
        return Inf
    end

    return velocita^2 / (2 * decelerazione)
end

# ============================================================
# CALCOLO DELLA VELOCITÀ SICURA
# ============================================================

function velocita_sicura(
    veicolo::Veicolo,
    strada::Rettilineo
)

    distanza_rimanente =
        strada.lunghezza -
        veicolo.posizione

    # Distanza necessaria per fermarsi
    distanza_stop =
        distanza_frenata(
            veicolo.velocita,
            veicolo.frenata_massima
        )

    # Se ci stiamo avvicinando alla fine
    if distanza_rimanente <=
       distanza_stop

        return sqrt(
            2 *
            veicolo.frenata_massima *
            max(distanza_rimanente, 0)
        )
    end

    return min(
        strada.velocita_limite,
        veicolo.velocita_massima
    )
end

# ============================================================
# CONTROLLO ACCELERAZIONE
# ============================================================

function controlla_accelerazione!(
    veicolo::Veicolo,
    velocita_target::Float64,
    intervallo::Float64
)

    errore =
        velocita_target -
        veicolo.velocita

    # Controllo proporzionale
    guadagno = 1.2

    accelerazione_comandata =
        errore * guadagno

    # Limitazione fisica
    accelerazione_comandata =
        clamp(
            accelerazione_comandata,
            -veicolo.frenata_massima,
            veicolo.accelerazione_massima
        )

    veicolo.accelerazione =
        accelerazione_comandata

    # Aggiornamento velocità
    veicolo.velocita +=
        veicolo.accelerazione *
        intervallo

    veicolo.velocita =
        clamp(
            veicolo.velocita,
            0.0,
            veicolo.velocita_massima
        )

    # Aggiornamento posizione
    veicolo.posizione +=
        veicolo.velocita *
        intervallo
end

# ============================================================
# CONTROLLO PRINCIPALE
# ============================================================

function controlla_rettilineo!(
    veicolo::Veicolo,
    strada::Rettilineo
)

    intervallo = 0.1

    println()
    println("==============================================")
    println("   CONTROLLO AUTOMATICO DEL RETTILINEO")
    println("==============================================")

    println(
        "Lunghezza strada: ",
        strada.lunghezza,
        " m"
    )

    println(
        "Limite velocità: ",
        @sprintf(
            "%.1f km/h",
            ms_a_kmh(strada.velocita_limite)
        )
    )

    println()

    while veicolo.posizione <
          strada.lunghezza

        target =
            velocita_sicura(
                veicolo,
                strada
            )

        controlla_accelerazione!(
            veicolo,
            target,
            intervallo
        )

        distanza =
            strada.lunghezza -
            veicolo.posizione

        println(
            @sprintf(
                "Posizione: %7.1f m | Velocità: %6.1f km/h | Target: %6.1f km/h | Accelerazione: %+5.2f m/s² | Distanza: %7.1f m",
                veicolo.posizione,
                ms_a_kmh(veicolo.velocita),
                ms_a_kmh(target),
                veicolo.accelerazione,
                max(distanza, 0)
            )
        )

        sleep(intervallo)
    end

    veicolo.velocita = 0.0
    veicolo.accelerazione = 0.0

    println()
    println("==============================================")
    println("            FINE DEL RETTILINEO")
    println("==============================================")

    println(
        "Posizione finale: ",
        @sprintf("%.1f m", veicolo.posizione)
    )

    println("Veicolo arrestato.")
end

# ============================================================
# AVVIO DEL SISTEMA
# ============================================================

println()
println("Sistema di controllo velocità avviato.")
println(
    "Ora: ",
    Dates.format(
        now(),
        "dd/mm/yyyy HH:MM:SS"
    )
)

controlla_rettilineo!(
    veicolo,
    strada
)


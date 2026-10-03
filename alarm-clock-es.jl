# ============================================================
# DESPERTADOR - JULIA
# Software de alarma en español
# ============================================================

using Dates

# ------------------------------------------------------------
# CONFIGURACIÓN
# ------------------------------------------------------------

mutable struct Alarma
    hora::Int
    minuto::Int
    activa::Bool
    dias::Vector{Int}
    sonido::String
end

# Días de la semana:
# 1 = lunes ... 7 = domingo

alarma = Alarma(
    7,
    30,
    false,
    [1, 2, 3, 4, 5],
    "ALARMA"
)

# ------------------------------------------------------------
# MOSTRAR HORA ACTUAL
# ------------------------------------------------------------

function mostrar_hora()
    ahora = now()

    println()
    println("======================================")
    println("          RELOJ DESPERTADOR")
    println("======================================")
    println("Fecha: ", Dates.format(ahora, "dd/mm/yyyy"))
    println("Hora : ", Dates.format(ahora, "HH:MM:SS"))
    println("======================================")
end

# ------------------------------------------------------------
# CONFIGURAR ALARMA
# ------------------------------------------------------------

function configurar_alarma!()

    println()
    println("CONFIGURACIÓN DE LA ALARMA")
    println("---------------------------")

    print("Hora (0-23): ")
    hora = parse(Int, readline())

    print("Minuto (0-59): ")
    minuto = parse(Int, readline())

    print("¿Activar alarma? (s/n): ")
    respuesta = lowercase(readline())

    alarma.hora = hora
    alarma.minuto = minuto
    alarma.activa = respuesta == "s"

    println()
    println("Alarma configurada para las ",
        lpad(hora, 2, '0'), ":",
        lpad(minuto, 2, '0'))

    if alarma.activa
        println("Estado: ACTIVADA")
    else
        println("Estado: DESACTIVADA")
    end
end

# ------------------------------------------------------------
# REPRODUCIR ALARMA
# ------------------------------------------------------------

function sonar_alarma()

    println()
    println("****************************************")
    println("          ¡¡¡ ALARMA !!!")
    println("****************************************")
    println("        ¡Buenos días!")
    println("        ¡Es hora de levantarse!")
    println("****************************************")

    # Beep de terminal
    for i in 1:5
        print('\a')
        sleep(0.5)
    end
end

# ------------------------------------------------------------
# POSPONER ALARMA
# ------------------------------------------------------------

function posponer(minutos::Int = 5)

    nueva_hora = now() + Minute(minutos)

    alarma.hora = hour(nueva_hora)
    alarma.minuto = minute(nueva_hora)
    alarma.activa = true

    println()
    println("Alarma pospuesta ", minutos, " minutos.")
    println(
        "Nueva alarma: ",
        lpad(alarma.hora, 2, '0'),
        ":",
        lpad(alarma.minuto, 2, '0')
    )
end

# ------------------------------------------------------------
# COMPROBAR ALARMA
# ------------------------------------------------------------

function comprobar_alarma()

    if !alarma.activa
        return
    end

    ahora = now()

    hora_actual = hour(ahora)
    minuto_actual = minute(ahora)

    if hora_actual == alarma.hora &&
       minuto_actual == alarma.minuto

        sonar_alarma()

        println()
        print("¿Posponer 5 minutos? (s/n): ")

        respuesta = lowercase(readline())

        if respuesta == "s"
            posponer(5)
        else
            alarma.activa = false
            println("Alarma desactivada.")
        end
    end
end

# ------------------------------------------------------------
# MOSTRAR ESTADO
# ------------------------------------------------------------

function mostrar_estado()

    println()
    println("ESTADO DEL DESPERTADOR")
    println("----------------------")

    if alarma.activa
        println(
            "Alarma: ",
            lpad(alarma.hora, 2, '0'),
            ":",
            lpad(alarma.minuto, 2, '0')
        )
        println("Estado: ACTIVADA")
    else
        println("Estado: DESACTIVADA")
    end
end

# ------------------------------------------------------------
# MENÚ PRINCIPAL
# ------------------------------------------------------------

function menu()

    while true

        mostrar_hora()

        println()
        println("1. Configurar alarma")
        println("2. Ver estado")
        println("3. Activar alarma")
        println("4. Desactivar alarma")
        println("5. Salir")
        println()

        print("Seleccione una opción: ")

        opcion = readline()

        if opcion == "1"

            configurar_alarma!()

        elseif opcion == "2"

            mostrar_estado()

        elseif opcion == "3"

            alarma.activa = true
            println("Alarma activada.")

        elseif opcion == "4"

            alarma.activa = false
            println("Alarma desactivada.")

        elseif opcion == "5"

            println("Cerrando despertador...")
            break

        else

            println("Opción no válida.")

        end

        # Comprobar la alarma varias veces por minuto
        for i in 1:10

            comprobar_alarma()
            sleep(1)

        end
    end
end

# ------------------------------------------------------------
# INICIO
# ------------------------------------------------------------

println()
println("Iniciando despertador...")
println("Sistema Julia activo.")

menu()

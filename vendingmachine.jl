using Dates
using Random
using Printf

# ============================================================
# RHINO VENDING ENGINE
# Julia 1.10+
# Enterprise-style vending machine simulation
# ============================================================

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

const MACHINE_ID = "RV-001"
const MACHINE_LOCATION = "Sheffield Central"

const MIN_TEMPERATURE = 2.0
const MAX_TEMPERATURE = 30.0

# ------------------------------------------------------------
# DATA STRUCTURES
# ------------------------------------------------------------

mutable struct Product
    id::String
    name::String
    category::String
    price::Float64
    stock::Int
    capacity::Int
    calories::Int
    active::Bool
end

mutable struct CashInventory
    coins::Dict{Float64, Int}
    notes::Dict{Float64, Int}
end

mutable struct Transaction
    id::String
    timestamp::DateTime
    product_id::String
    product_name::String
    payment_method::String
    amount_paid::Float64
    change_given::Float64
    status::String
end

mutable struct VendingMachine
    id::String
    location::String
    products::Dict{String, Product}
    cash::CashInventory
    transactions::Vector{Transaction}
    temperature::Float64
    door_open::Bool
    operational::Bool
    total_revenue::Float64
end

# ------------------------------------------------------------
# MACHINE INITIALISATION
# ------------------------------------------------------------

function create_machine()

    products = Dict(
        "A1" => Product(
            "A1",
            "Coca-Cola",
            "Drink",
            1.80,
            8,
            12,
            139,
            true
        ),

        "A2" => Product(
            "A2",
            "Mineral Water",
            "Drink",
            1.20,
            10,
            12,
            0,
            true
        ),

        "A3" => Product(
            "A3",
            "Orange Juice",
            "Drink",
            2.20,
            6,
            10,
            110,
            true
        ),

        "B1" => Product(
            "B1",
            "Crisps",
            "Snack",
            1.50,
            7,
            10,
            180,
            true
        ),

        "B2" => Product(
            "B2",
            "Chocolate Bar",
            "Snack",
            1.70,
            5,
            10,
            230,
            true
        ),

        "B3" => Product(
            "B3",
            "Protein Bar",
            "Snack",
            2.80,
            4,
            8,
            210,
            true
        ),

        "C1" => Product(
            "C1",
            "Sandwich",
            "Food",
            4.50,
            3,
            6,
            420,
            true
        )
    )

    coins = Dict(
        0.01 => 50,
        0.02 => 50,
        0.05 => 50,
        0.10 => 40,
        0.20 => 40,
        0.50 => 30,
        1.00 => 30,
        2.00 => 20
    )

    notes = Dict(
        5.00 => 10,
        10.00 => 5,
        20.00 => 2
    )

    cash = CashInventory(coins, notes)

    return VendingMachine(
        MACHINE_ID,
        MACHINE_LOCATION,
        products,
        cash,
        Transaction[],
        5.5,
        false,
        true,
        0.0
    )
end

# ------------------------------------------------------------
# DISPLAY
# ------------------------------------------------------------

function print_header(machine)

    println()
    println("============================================================")
    println("                 RHINO VENDING SYSTEM")
    println("============================================================")
    println("Machine:   ", machine.id)
    println("Location:  ", machine.location)
    println("Time:      ", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
    println("Status:    ", machine.operational ? "ONLINE" : "OFFLINE")
    println("============================================================")
end

function display_products(machine)

    println()
    println("PRODUCTS")
    println("------------------------------------------------------------")

    for (id, product) in sort(collect(machine.products))

        if product.active

            stock_status =
                product.stock == 0 ? "SOLD OUT" :
                product.stock <= 2 ? "LOW STOCK" :
                "$(product.stock) available"

            @printf(
                "%-4s %-20s £%5.2f   %-12s\n",
                id,
                product.name,
                product.price,
                stock_status
            )
        end
    end

    println("------------------------------------------------------------")
end

# ------------------------------------------------------------
# PRODUCT LOOKUP
# ------------------------------------------------------------

function get_product(machine, id)

    id = uppercase(strip(id))

    if !haskey(machine.products, id)
        return nothing
    end

    return machine.products[id]
end

# ------------------------------------------------------------
# CASH CALCULATION
# ------------------------------------------------------------

function cash_available(machine)

    total = 0.0

    for (value, count) in machine.cash.coins
        total += value * count
    end

    for (value, count) in machine.cash.notes
        total += value * count
    end

    return round(total, digits=2)
end

function add_cash!(machine, amount)

    amount = round(amount, digits=2)

    denominations = sort(
        collect(keys(machine.cash.coins))
    )

    for denomination in denominations
        if isapprox(amount, denomination; atol=0.001)
            machine.cash.coins[denomination] += 1
            return true
        end
    end

    notes = sort(
        collect(keys(machine.cash.notes))
    )

    for denomination in notes
        if isapprox(amount, denomination; atol=0.001)
            machine.cash.notes[denomination] += 1
            return true
        end
    end

    return false
end

# ------------------------------------------------------------
# CHANGE ALGORITHM
# ------------------------------------------------------------

function calculate_change(machine, change_required)

    change_required = round(change_required, digits=2)

    if change_required <= 0
        return Dict{Float64,Int}()
    end

    denominations = vcat(
        collect(keys(machine.cash.notes)),
        collect(keys(machine.cash.coins))
    )

    sort!(denominations, rev=true)

    remaining = change_required
    result = Dict{Float64,Int}()

    for denomination in denominations

        available =
            haskey(machine.cash.coins, denomination) ?
            machine.cash.coins[denomination] :
            machine.cash.notes[denomination]

        needed = floor(Int, remaining / denomination)

        use = min(needed, available)

        if use > 0

            result[denomination] = use

            remaining -= denomination * use
            remaining = round(remaining, digits=2)
        end
    end

    if remaining > 0.001
        return nothing
    end

    return result
end

function remove_change!(machine, change)

    for (denomination, count) in change

        if haskey(machine.cash.coins, denomination)
            machine.cash.coins[denomination] -= count

        elseif haskey(machine.cash.notes, denomination)
            machine.cash.notes[denomination] -= count
        end
    end
end

function print_change(change)

    println()
    println("CHANGE")
    println("------------------------------------------------------------")

    if isempty(change)
        println("No change")
        return
    end

    for (value, count) in sort(collect(change), rev=true)
        @printf("%dx £%.2f\n", count, value)
    end
end

# ------------------------------------------------------------
# CASH PAYMENT
# ------------------------------------------------------------

function cash_payment!(machine, price)

    println()
    println("Price: £", @sprintf("%.2f", price))
    println()
    println("Insert denominations individually.")
    println("Enter 0 when payment is complete.")

    inserted = 0.0

    while inserted < price

        @printf(
            "Inserted: £%.2f | Remaining: £%.2f\n",
            inserted,
            max(price - inserted, 0)
        )

        print("Insert £")

        input = readline()

        value = try
            parse(Float64, input)
        catch
            println("Invalid denomination.")
            continue
        end

        if value == 0
            break
        end

        valid_denominations = [
            0.01, 0.02, 0.05,
            0.10, 0.20, 0.50,
            1.00, 2.00,
            5.00, 10.00, 20.00
        ]

        if !(any(isapprox(value, d; atol=0.001)
                 for d in valid_denominations))

            println("Denomination not accepted.")
            continue
        end

        inserted += value
        inserted = round(inserted, digits=2)

        add_cash!(machine, value)
    end

    if inserted < price

        println("Payment cancelled.")

        return false, inserted, 0.0
    end

    change_required =
        round(inserted - price, digits=2)

    change =
        calculate_change(machine, change_required)

    if change === nothing

        println()
        println("ERROR: Machine cannot provide exact change.")

        return false, inserted, 0.0
    end

    remove_change!(machine, change)

    print_change(change)

    return true, inserted, change_required
end

# ------------------------------------------------------------
# CARD PAYMENT
# ------------------------------------------------------------

function card_payment!(machine, price)

    println()
    println("CARD PAYMENT")
    println("Amount: £", @sprintf("%.2f", price))

    print("Tap/insert card? [y/n]: ")

    answer = lowercase(strip(readline()))

    if answer != "y"
        println("Card payment cancelled.")
        return false
    end

    println("Authorising payment...")

    sleep(0.5)

    # Simulation of payment gateway response
    approved = rand() > 0.05

    if approved
        println("Payment authorised.")
        return true
    end

    println("Payment declined.")

    return false
end

# ------------------------------------------------------------
# PRODUCT DISPENSING
# ------------------------------------------------------------

function dispense_product!(machine, product)

    println()
    println("Dispensing ", product.name, "...")

    sleep(0.4)

    # Simulated motor cycle
    println("[MOTOR] Starting...")
    sleep(0.2)

    println("[MOTOR] Product released.")
    sleep(0.2)

    println("[SENSOR] Product detected.")

    product.stock -= 1

    return true
end

# ------------------------------------------------------------
# TRANSACTION ID
# ------------------------------------------------------------

function transaction_id()

    return "TX-" *
           Dates.format(now(), "yyyymmddHHMMSS") *
           "-" *
           string(rand(100:999))
end

# ------------------------------------------------------------
# PURCHASE
# ------------------------------------------------------------

function purchase!(machine, id)

    if !machine.operational
        println("Machine is currently offline.")
        return
    end

    product = get_product(machine, id)

    if product === nothing
        println("Unknown product.")
        return
    end

    if !product.active
        println("Product unavailable.")
        return
    end

    if product.stock <= 0
        println("Product sold out.")
        return
    end

    println()
    println("Selected: ", product.name)
    println("Price: £", @sprintf("%.2f", product.price))

    println()
    println("Payment method:")
    println("1. Cash")
    println("2. Card")

    print("Select: ")

    method = strip(readline())

    success = false
    paid = 0.0
    change = 0.0
    payment_name = ""

    if method == "1"

        payment_name = "CASH"

        success,
        paid,
        change = cash_payment!(
            machine,
            product.price
        )

    elseif method == "2"

        payment_name = "CARD"

        success = card_payment!(
            machine,
            product.price
        )

        paid = product.price

    else

        println("Invalid payment method.")
        return
    end

    if !success
        return
    end

    if dispense_product!(machine, product)

        tx = Transaction(
            transaction_id(),
            now(),
            product.id,
            product.name,
            payment_name,
            paid,
            change,
            "COMPLETED"
        )

        push!(
            machine.transactions,
            tx
        )

        machine.total_revenue += product.price

        println()
        println("============================================================")
        println("                 PURCHASE COMPLETE")
        println("============================================================")
        println("Product: ", product.name)
        println("Paid:    £", @sprintf("%.2f", paid))
        println("Price:   £", @sprintf("%.2f", product.price))
        println("Change:  £", @sprintf("%.2f", change))
        println("============================================================")
    end
end

# ------------------------------------------------------------
# RESTOCKING
# ------------------------------------------------------------

function restock!(machine, id, quantity)

    product = get_product(machine, id)

    if product === nothing
        println("Unknown product.")
        return
    end

    old_stock = product.stock

    product.stock = min(
        product.capacity,
        product.stock + quantity
    )

    added = product.stock - old_stock

    println(
        product.name,
        " restocked by ",
        added,
        ". Current stock: ",
        product.stock
    )
end

function restock_all!(machine)

    for product in values(machine.products)
        product.stock = product.capacity
    end

    println("All products restocked.")
end

# ------------------------------------------------------------
# MACHINE DIAGNOSTICS
# ------------------------------------------------------------

function diagnostics(machine)

    println()
    println("============================================================")
    println("                  MACHINE DIAGNOSTICS")
    println("============================================================")

    println("Machine ID:      ", machine.id)
    println("Location:        ", machine.location)
    println("Operational:     ", machine.operational)
    println("Door:            ", machine.door_open ? "OPEN" : "CLOSED")

    @printf(
        "Temperature:     %.1f °C\n",
        machine.temperature
    )

    println(
        "Cash reserve:    £",
        @sprintf("%.2f", cash_available(machine))
    )

    println(
        "Revenue:         £",
        @sprintf("%.2f", machine.total_revenue)
    )

    println(
        "Transactions:    ",
        length(machine.transactions)
    )

    println()
    println("SYSTEM CHECKS")
    println("------------------------------------------------------------")

    println(
        "[",
        machine.temperature >= MIN_TEMPERATURE &&
        machine.temperature <= MAX_TEMPERATURE ?
        "OK" : "FAIL",
        "] Temperature"
    )

    println(
        "[",
        machine.door_open ? "FAIL" : "OK",
        "] Door sensor"
    )

    println(
        "[",
        machine.operational ? "OK" : "FAIL",
        "] Controller"
    )

    println("============================================================")
end

# ------------------------------------------------------------
# INVENTORY REPORT
# ------------------------------------------------------------

function inventory_report(machine)

    println()
    println("============================================================")
    println("                  INVENTORY REPORT")
    println("============================================================")

    for product in values(machine.products)

        percentage =
            100 * product.stock / product.capacity

        @printf(
            "%-4s %-20s %2d/%2d  %5.1f%%\n",
            product.id,
            product.name,
            product.stock,
            product.capacity,
            percentage
        )
    end

    println("============================================================")
end

# ------------------------------------------------------------
# SALES REPORT
# ------------------------------------------------------------

function sales_report(machine)

    println()
    println("============================================================")
    println("                    SALES REPORT")
    println("============================================================")

    println(
        "Total revenue: £",
        @sprintf("%.2f", machine.total_revenue)
    )

    println(
        "Transactions: ",
        length(machine.transactions)
    )

    println()
    println("TRANSACTIONS")
    println("------------------------------------------------------------")

    for tx in machine.transactions

        println(
            tx.id,
            " | ",
            tx.product_name,
            " | ",
            tx.payment_method,
            " | £",
            @sprintf("%.2f", tx.product_name == "" ? 0 :
                tx.amount_paid),
            " | ",
            tx.status
        )
    end

    println("============================================================")
end

# ------------------------------------------------------------
# ADMIN MODE
# ------------------------------------------------------------

function admin_menu(machine)

    while true

        println()
        println("============================================================")
        println("                    ADMIN MODE")
        println("============================================================")
        println("1. Inventory report")
        println("2. Sales report")
        println("3. Diagnostics")
        println("4. Restock product")
        println("5. Restock everything")
        println("6. Set temperature")
        println("7. Machine ON/OFF")
        println("8. Empty cash")
        println("9. Return")
        println("============================================================")

        print("Select: ")

        choice = strip(readline())

        if choice == "1"

            inventory_report(machine)

        elseif choice == "2"

            sales_report(machine)

        elseif choice == "3"

            diagnostics(machine)

        elseif choice == "4"

            print("Product ID: ")
            id = readline()

            print("Quantity: ")
            quantity = try
                parse(Int, readline())
            catch
                0
            end

            restock!(machine, id, quantity)

        elseif choice == "5"

            restock_all!(machine)

        elseif choice == "6"

            print("Temperature °C: ")

            temp = try
                parse(Float64, readline())
            catch
                machine.temperature
            end

            machine.temperature = temp

            println("Temperature updated.")

        elseif choice == "7"

            machine.operational =
                !machine.operational

            println(
                "Machine is now ",
                machine.operational ?
                "ONLINE" : "OFFLINE"
            )

        elseif choice == "8"

            empty!(machine.cash.coins)
            empty!(machine.cash.notes)

            println("Cash reserves emptied.")

        elseif choice == "9"

            return

        else

            println("Invalid selection.")
        end
    end
end

# ------------------------------------------------------------
# MAIN USER INTERFACE
# ------------------------------------------------------------

function main_menu(machine)

    while true

        print_header(machine)
        display_products(machine)

        println()
        println("1. Buy product")
        println("2. Admin mode")
        println("3. Diagnostics")
        println("4. Exit")

        print("Select: ")

        choice = strip(readline())

        if choice == "1"

            print("Enter product ID: ")

            id = readline()

            purchase!(
                machine,
                id
            )

        elseif choice == "2"

            admin_menu(machine)

        elseif choice == "3"

            diagnostics(machine)

            println()
            print("Press ENTER to continue...")
            readline()

        elseif choice == "4"

            println("Shutting down vending interface.")
            break

        else

            println("Invalid selection.")
        end
    end
end

# ------------------------------------------------------------
# START SYSTEM
# ------------------------------------------------------------

function main()

    machine = create_machine()

    println()
    println("Booting Rhino Vending Controller...")

    sleep(0.5)

    println("[OK] Main controller")
    println("[OK] Inventory database")
    println("[OK] Payment controller")
    println("[OK] Motor controller")
    println("[OK] Product sensors")
    println("[OK] Temperature sensor")
    println("[OK] Cash subsystem")

    sleep(0.5)

    println()
    println("System ready.")

    main_menu(machine)
end

main()

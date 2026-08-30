module OpenAllHours

using Printf
using Dates

# ============================================================
# OPENALLHOURS
#
# ANALOGUE-STYLE PUB TILL
#
# Pure Julia
# No external packages
#
# Design:
#   - Cash first
#   - Keyboard first
#   - Minimal UI
#   - Fast transactions
#   - Simple accounting
#   - Offline capable
#   - Audit trail
# ============================================================


# ============================================================
# PRODUCT
# ============================================================

struct Product
    id::Int
    name::String
    category::String
    price::Float64
end


# ============================================================
# SALE LINE
# ============================================================

struct SaleLine
    product::Product
    quantity::Int
end


function line_total(line::SaleLine)
    line.product.price * line.quantity
end


# ============================================================
# SALE
# ============================================================

mutable struct Sale
    id::Int
    timestamp::DateTime
    lines::Vector{SaleLine}

    subtotal::Float64
    discount::Float64
    total::Float64

    cash_received::Float64
    change_given::Float64

    status::Symbol
end


function Sale(id::Int)

    Sale(
        id,
        now(),
        SaleLine[],
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        :OPEN
    )
end


# ============================================================
# TILL
# ============================================================

mutable struct Till

    name::String

    opening_float::Float64

    cash_drawer::Float64

    sales::Vector{Sale}

    refunds::Vector{Sale}

    next_sale_id::Int

    current_sale::Union{Sale,Nothing}
end


function Till(
    name::String;
    opening_float=100.0
)

    Till(
        name,
        opening_float,
        opening_float,
        Sale[],
        Sale[],
        1,
        nothing
    )
end


# ============================================================
# PRODUCT DATABASE
# ============================================================

mutable struct ProductCatalogue

    products::Dict{Int,Product}
end


function ProductCatalogue()

    ProductCatalogue(
        Dict{Int,Product}()
    )
end


function add_product!(
    catalogue::ProductCatalogue,
    product::Product
)

    catalogue.products[product.id] =
        product

    return product
end


function get_product(
    catalogue::ProductCatalogue,
    id::Int
)

    get(
        catalogue.products,
        id,
        nothing
    )
end


# ============================================================
# SALE OPERATIONS
# ============================================================

function new_sale!(
    till::Till
)

    if till.current_sale !== nothing
        error("A sale is already open.")
    end

    sale =
        Sale(
            till.next_sale_id
        )

    till.next_sale_id += 1

    till.current_sale =
        sale

    return sale
end


function add_item!(
    till::Till,
    product::Product,
    quantity::Int=1
)

    quantity > 0 ||
        error("Quantity must be positive.")

    sale =
        till.current_sale

    sale === nothing &&
        error("No open sale.")

    # Merge identical products.

    found = false

    for i in eachindex(sale.lines)

        if sale.lines[i].product.id ==
           product.id

            old =
                sale.lines[i]

            sale.lines[i] =
                SaleLine(
                    old.product,
                    old.quantity + quantity
                )

            found = true
            break
        end
    end

    if !found

        push!(
            sale.lines,
            SaleLine(
                product,
                quantity
            )
        )
    end

    recalculate!(sale)

    return sale
end


function remove_item!(
    till::Till,
    product_id::Int
)

    sale =
        till.current_sale

    sale === nothing &&
        error("No open sale.")

    filter!(
        line ->
            line.product.id != product_id,
        sale.lines
    )

    recalculate!(sale)

    return sale
end


function recalculate!(
    sale::Sale
)

    subtotal =
        sum(
            line_total(line)
            for line in sale.lines
        )

    sale.subtotal =
        round(
            subtotal,
            digits=2
        )

    sale.total =
        round(
            sale.subtotal -
            sale.discount,
            digits=2
        )

    return sale
end


# ============================================================
# DISCOUNTS
# ============================================================

function apply_discount!(
    till::Till,
    amount::Float64
)

    sale =
        till.current_sale

    sale === nothing &&
        error("No open sale.")

    amount >= 0 ||
        error("Invalid discount.")

    amount <= sale.subtotal ||
        error("Discount exceeds sale value.")

    sale.discount =
        round(
            amount,
            digits=2
        )

    recalculate!(sale)

    return sale
end


# ============================================================
# CASH PAYMENT
# ============================================================

function calculate_change(
    total::Float64,
    cash::Float64
)

    cash >= total ||
        error("Insufficient cash.")

    round(
        cash - total,
        digits=2
    )
end


function pay_cash!(
    till::Till,
    cash_received::Float64
)

    sale =
        till.current_sale

    sale === nothing &&
        error("No open sale.")

    cash_received >= sale.total ||
        error("Insufficient cash.")

    change =
        calculate_change(
            sale.total,
            cash_received
        )

    sale.cash_received =
        round(
            cash_received,
            digits=2
        )

    sale.change_given =
        change

    sale.status =
        :COMPLETED

    till.cash_drawer +=
        sale.total

    push!(
        till.sales,
        sale
    )

    till.current_sale =
        nothing

    return change
end


# ============================================================
# VOID
# ============================================================

function void_sale!(
    till::Till
)

    sale =
        till.current_sale

    sale === nothing &&
        error("No open sale.")

    sale.status =
        :VOID

    till.current_sale =
        nothing

    return sale
end


# ============================================================
# REFUND
# ============================================================

function refund!(
    till::Till,
    sale_id::Int
)

    original =
        findfirst(
            sale -> sale.id == sale_id,
            till.sales
        )

    original === nothing &&
        error("Sale not found.")

    sale =
        till.sales[original]

    sale.status == :COMPLETED ||
        error("Sale cannot be refunded.")

    refund_sale =
        Sale(
            till.next_sale_id
        )

    till.next_sale_id += 1

    refund_sale.lines =
        sale.lines

    refund_sale.subtotal =
        -sale.total

    refund_sale.total =
        -sale.total

    refund_sale.status =
        :REFUND

    push!(
        till.refunds,
        refund_sale
    )

    till.cash_drawer -=
        sale.total

    return refund_sale
end


# ============================================================
# RECEIPT
# ============================================================

function receipt_text(
    sale::Sale,
    till_name::String
)

    io =
        IOBuffer()

    println(
        io,
        "="^40
    )

    println(
        io,
        uppercase(till_name)
    )

    println(
        io,
        "OPENALLHOURS"
    )

    println(
        io,
        "="^40
    )

    println(
        io,
        "SALE #",
        sale.id
    )

    println(
        io,
        sale.timestamp
    )

    println(
        io,
        "-"^40
    )

    for line in sale.lines

        @printf(
            io,
            "%-22s %2dx £%6.2f\n",
            line.product.name,
            line.quantity,
            line_total(line)
        )
    end

    println(
        io,
        "-"^40
    )

    @printf(
        io,
        "%-28s £%7.2f\n",
        "SUBTOTAL",
        sale.subtotal
    )

    @printf(
        io,
        "%-28s £%7.2f\n",
        "DISCOUNT",
        sale.discount
    )

    @printf(
        io,
        "%-28s £%7.2f\n",
        "TOTAL",
        sale.total
    )

    @printf(
        io,
        "%-28s £%7.2f\n",
        "CASH",
        sale.cash_received
    )

    @printf(
        io,
        "%-28s £%7.2f\n",
        "CHANGE",
        sale.change_given
    )

    println(
        io,
        "="^40
    )

    println(
        io,
        "THANK YOU"
    )

    return String(
        take!(io)
    )
end


# ============================================================
# TILL REPORT
# ============================================================

struct TillReport

    opening_float::Float64

    gross_sales::Float64

    refunds::Float64

    net_sales::Float64

    expected_cash::Float64

    actual_cash::Float64

    variance::Float64

    transaction_count::Int
end


function generate_report(
    till::Till,
    actual_cash::Float64
)

    gross =
        sum(
            sale.total
            for sale in till.sales
            if sale.status == :COMPLETED
        )

    refunds_total =
        sum(
            -refund.total
            for refund in till.refunds
        )

    net =
        gross -
        refunds_total

    expected =
        till.opening_float +
        net

    variance =
        actual_cash -
        expected

    TillReport(
        till.opening_float,
        gross,
        refunds_total,
        net,
        expected,
        actual_cash,
        variance,
        length(till.sales)
    )
end


function print_report(
    report::TillReport
)

    println()
    println("="^50)
    println(" OPENALLHOURS — END OF SHIFT")
    println("="^50)

    @printf(
        "Opening float:       £%9.2f\n",
        report.opening_float
    )

    @printf(
        "Gross sales:         £%9.2f\n",
        report.gross_sales
    )

    @printf(
        "Refunds:             £%9.2f\n",
        report.refunds
    )

    @printf(
        "Net sales:           £%9.2f\n",
        report.net_sales
    )

    @printf(
        "Expected cash:       £%9.2f\n",
        report.expected_cash
    )

    @printf(
        "Actual cash:         £%9.2f\n",
        report.actual_cash
    )

    @printf(
        "Cash variance:       £%9.2f\n",
        report.variance
    )

    println(
        "Transactions:        ",
        report.transaction_count
    )

    println("="^50)
end


# ============================================================
# SIMPLE TEXT TERMINAL
# ============================================================

function show_products(
    catalogue::ProductCatalogue
)

    println()
    println(
        "---------------- PRODUCTS ----------------"
    )

    ids =
        sort(
            collect(
                keys(catalogue.products)
            )
        )

    for id in ids

        product =
            catalogue.products[id]

        @printf(
            "%3d  %-25s £%6.2f\n",
            product.id,
            product.name,
            product.price
        )
    end

    println(
        "-------------------------------------------"
    )
end


function show_sale(
    till::Till
)

    sale =
        till.current_sale

    if sale === nothing

        println("NO OPEN SALE")
        return
    end

    println()
    println(
        "--------------- CURRENT SALE -------------"
    )

    for line in sale.lines

        @printf(
            "%2dx %-25s £%7.2f\n",
            line.quantity,
            line.product.name,
            line_total(line)
        )
    end

    println(
        "-------------------------------------------"
    )

    @printf(
        "TOTAL                         £%7.2f\n",
        sale.total
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    catalogue =
        ProductCatalogue()

    add_product!(
        catalogue,
        Product(
            1,
            "Lager",
            "Beer",
            4.80
        )
    )

    add_product!(
        catalogue,
        Product(
            2,
            "Guinness",
            "Beer",
            5.40
        )
    )

    add_product!(
        catalogue,
        Product(
            3,
            "Cider",
            "Beer",
            5.00
        )
    )

    add_product!(
        catalogue,
        Product(
            4,
            "House Ale",
            "Beer",
            4.60
        )
    )

    add_product!(
        catalogue,
        Product(
            5,
            "House Wine",
            "Wine",
            6.00
        )
    )

    add_product!(
        catalogue,
        Product(
            6,
            "Spirit + Mixer",
            "Spirits",
            4.20
        )
    )

    add_product!(
        catalogue,
        Product(
            7,
            "Soft Drink",
            "Soft",
            2.20
        )
    )

    till =
        Till(
            "THE OPEN ALL HOURS"
        )

    println()
    println(
        "============================================"
    )
    println(
        "       OPENALLHOURS PUB TILL"
    )
    println(
        "============================================"
    )

    show_products(
        catalogue
    )

    # ----------------------------------------
    # Example transaction
    # ----------------------------------------

    new_sale!(till)

    add_item!(
        till,
        get_product(catalogue, 2)
    )

    add_item!(
        till,
        get_product(catalogue, 1)
    )

    add_item!(
        till,
        get_product(catalogue, 7)
    )

    show_sale(till)

    println()
    println("Cash received: £20.00")

    change =
        pay_cash!(
            till,
            20.00
        )

    println(
        "CHANGE: £",
        @sprintf("%.2f", change)
    )

    sale =
        till.sales[end]

    println()
    println(
        receipt_text(
            sale,
            till.name
        )
    )

    # ----------------------------------------
    # Second transaction
    # ----------------------------------------

    new_sale!(till)

    add_item!(
        till,
        get_product(catalogue, 3),
        2
    )

    add_item!(
        till,
        get_product(catalogue, 4)
    )

    apply_discount!(
        till,
        1.00
    )

    pay_cash!(
        till,
        20.00
    )

    # ----------------------------------------
    # End-of-shift reconciliation
    # ----------------------------------------

    println()
    println(
        "END OF SHIFT"
    )

    report =
        generate_report(
            till,
            till.cash_drawer
        )

    print_report(report)

    return till
end


# ============================================================
# EXPORTS
# ============================================================

export Product
export SaleLine
export Sale
export Till
export ProductCatalogue
export TillReport

export add_product!
export get_product

export new_sale!
export add_item!
export remove_item!
export apply_discount!
export pay_cash!
export void_sale!
export refund!

export receipt_text

export generate_report
export print_report

export show_products
export show_sale

export demo


end # module OpenAllHours


# ============================================================
# RUN DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .OpenAllHours

    OpenAllHours.demo()

end

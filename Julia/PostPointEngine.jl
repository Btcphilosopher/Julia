```julia
# ================================================================
# POSTPOINT ENGINE
#
# Industry-grade-ish Julia transaction engine for a
# self-service postal / packaging touchscreen kiosk.
#
# The touchscreen itself is NOT implemented here.
# This is the engine underneath the touchscreen.
#
# Handles:
#   - Customer session
#   - Destination
#   - Letters / parcels
#   - Weight
#   - Dimensions
#   - Packaging products
#   - Postage services
#   - Price calculation
#   - Basket
#   - Discounts / surcharges
#   - Payment state
#   - Receipt generation
#   - Transaction state machine
#   - Kiosk inventory
#   - Error handling
#
# Prices below are DEMONSTRATION VALUES only.
# ================================================================

using Dates
using UUIDs
using Printf

# ================================================================
# ENUMERATIONS
# ================================================================

@enum DestinationType begin
    UK
    EUROPE
    INTERNATIONAL
end

@enum ItemType begin
    LETTER
    LARGE_LETTER
    PARCEL
end

@enum PaymentStatus begin
    PAYMENT_PENDING
    PAYMENT_AUTHORISED
    PAYMENT_DECLINED
    PAYMENT_CANCELLED
end

@enum TransactionStatus begin
    STARTED
    ITEM_CONFIGURED
    BASKET_READY
    PAYMENT_PROCESSING
    COMPLETED
    CANCELLED
    ERROR
end

# ================================================================
# POSTAL ITEM
# ================================================================

struct PostalItem

    item_type::ItemType

    weight_g::Float64

    length_mm::Float64
    width_mm::Float64
    height_mm::Float64

    destination::DestinationType
end


function volume_cm3(
    item::PostalItem
)

    return (
        item.length_mm *
        item.width_mm *
        item.height_mm
    ) / 1000.0
end


function volumetric_weight_g(
    item::PostalItem
)

    # Demonstration volumetric divisor

    return volume_cm3(item) * 0.20
end


function billable_weight(
    item::PostalItem
)

    return max(
        item.weight_g,
        volumetric_weight_g(item)
    )
end

# ================================================================
# POSTAGE SERVICE
# ================================================================

struct PostalService

    id::String

    name::String

    destination::DestinationType

    max_weight_g::Float64

    max_length_mm::Float64

    max_width_mm::Float64

    max_height_mm::Float64

    base_price::Float64

    price_per_500g::Float64

    tracking::Bool

    signature::Bool

    estimated_days::String
end

# ================================================================
# PACKAGING PRODUCT
# ================================================================

struct PackagingProduct

    id::String

    name::String

    description::String

    price::Float64

    max_length_mm::Float64

    max_width_mm::Float64

    max_height_mm::Float64

    stock::Int
end

# ================================================================
# BASKET LINE
# ================================================================

mutable struct BasketLine

    description::String

    quantity::Int

    unit_price::Float64
end


function line_total(
    line::BasketLine
)

    return (
        line.quantity *
        line.unit_price
    )
end

# ================================================================
# BASKET
# ================================================================

mutable struct Basket

    lines::Vector{BasketLine}

    subtotal::Float64

    discount::Float64

    surcharge::Float64

    total::Float64
end


function Basket()

    return Basket(
        BasketLine[],
        0.0,
        0.0,
        0.0,
        0.0
    )
end


function recalculate!(
    basket::Basket
)

    basket.subtotal =
        sum(
            line_total(line)
            for line in basket.lines
        )

    basket.total =
        max(
            0.0,
            basket.subtotal -
            basket.discount +
            basket.surcharge
        )

    return basket.total
end


function add_line!(
    basket::Basket,
    description::String,
    price::Float64,
    quantity::Int = 1
)

    push!(
        basket.lines,
        BasketLine(
            description,
            quantity,
            price
        )
    )

    recalculate!(
        basket
    )
end

# ================================================================
# KIOSK INVENTORY
# ================================================================

mutable struct KioskInventory

    products::Dict{String,PackagingProduct}

    paper_remaining::Int

    receipt_roll_remaining::Int
end


function stock_product!(
    inventory::KioskInventory,
    product::PackagingProduct
)

    inventory.products[
        product.id
    ] = product
end


function available_stock(
    inventory::KioskInventory,
    id::String
)

    if !haskey(
        inventory.products,
        id
    )

        return 0
    end

    return inventory.products[id].stock
end

# ================================================================
# CUSTOMER SESSION
# ================================================================

mutable struct CustomerSession

    id::UUID

    started_at::DateTime

    status::TransactionStatus

    destination::Union{
        Nothing,
        DestinationType
    }

    postal_item::Union{
        Nothing,
        PostalItem
    }

    selected_service::Union{
        Nothing,
        PostalService
    }

    basket::Basket

    payment_status::PaymentStatus

    payment_reference::Union{
        Nothing,
        String
    }

    receipt_number::Union{
        Nothing,
        String
    }

    error_message::Union{
        Nothing,
        String
    }
end


function new_session()

    return CustomerSession(

        uuid4(),

        now(),

        STARTED,

        nothing,

        nothing,

        nothing,

        Basket(),

        PAYMENT_PENDING,

        nothing,

        nothing,

        nothing
    )
end

# ================================================================
# DEMONSTRATION SERVICE CATALOGUE
# ================================================================

const SERVICES = [

    PostalService(
        "UK-ECO",
        "UK Economy",
        UK,
        2000.0,
        450.0,
        350.0,
        160.0,
        3.50,
        0.60,
        false,
        false,
        "2–4 working days"
    ),

    PostalService(
        "UK-TRACKED",
        "UK Tracked",
        UK,
        20000.0,
        600.0,
        450.0,
        300.0,
        5.50,
        0.80,
        true,
        false,
        "1–2 working days"
    ),

    PostalService(
        "UK-SIGNED",
        "UK Signed",
        UK,
        20000.0,
        600.0,
        450.0,
        300.0,
        7.50,
        0.80,
        true,
        true,
        "1–2 working days"
    ),

    PostalService(
        "EU-TRACKED",
        "Europe Tracked",
        EUROPE,
        20000.0,
        600.0,
        450.0,
        300.0,
        12.00,
        2.00,
        true,
        false,
        "3–7 working days"
    ),

    PostalService(
        "INT-TRACKED",
        "International Tracked",
        INTERNATIONAL,
        20000.0,
        600.0,
        450.0,
        300.0,
        18.00,
        3.50,
        true,
        false,
        "5–14 working days"
    )
]

# ================================================================
# PACKAGING CATALOGUE
# ================================================================

function create_inventory()

    inventory =
        KioskInventory(
            Dict{String,PackagingProduct}(),
            5000,
            1000
        )

    products = [

        PackagingProduct(
            "ENV-S",
            "Small Postal Envelope",
            "Protective small envelope",
            0.60,
            240.0,
            165.0,
            10.0,
            100
        ),

        PackagingProduct(
            "ENV-L",
            "Large Postal Envelope",
            "Protective large envelope",
            1.00,
            350.0,
            250.0,
            20.0,
            80
        ),

        PackagingProduct(
            "BOX-S",
            "Small Parcel Box",
            "Rigid small parcel box",
            1.50,
            300.0,
            200.0,
            150.0,
            60
        ),

        PackagingProduct(
            "BOX-M",
            "Medium Parcel Box",
            "Rigid medium parcel box",
            2.25,
            450.0,
            300.0,
            200.0,
            40
        ),

        PackagingProduct(
            "BOX-L",
            "Large Parcel Box",
            "Rigid large parcel box",
            3.50,
            600.0,
            450.0,
            300.0,
            25
        ),

        PackagingProduct(
            "BUBBLE-S",
            "Small Padded Mailer",
            "Bubble-lined protective mailer",
            1.25,
            300.0,
            220.0,
            40.0,
            50
        )
    ]

    for product in products
        stock_product!(
            inventory,
            product
        )
    end

    return inventory
end

# ================================================================
# DESTINATION
# ================================================================

function set_destination!(
    session::CustomerSession,
    destination::DestinationType
)

    session.destination =
        destination

    return true
end

# ================================================================
# ITEM CONFIGURATION
# ================================================================

function configure_item!(
    session::CustomerSession,

    item_type::ItemType,

    weight_g::Real,

    length_mm::Real,

    width_mm::Real,

    height_mm::Real
)

    if weight_g <= 0

        session.status = ERROR
        session.error_message =
            "Weight must be greater than zero."

        return false
    end

    if any(
        x <= 0
        for x in (
            length_mm,
            width_mm,
            height_mm
        )
    )

        session.status = ERROR
        session.error_message =
            "Dimensions must be greater than zero."

        return false
    end

    if session.destination === nothing

        session.status = ERROR
        session.error_message =
            "Destination has not been selected."

        return false
    end

    session.postal_item =
        PostalItem(

            item_type,

            Float64(weight_g),

            Float64(length_mm),

            Float64(width_mm),

            Float64(height_mm),

            session.destination
        )

    session.status =
        ITEM_CONFIGURED

    return true
end

# ================================================================
# SERVICE ELIGIBILITY
# ================================================================

function service_available(
    item::PostalItem,
    service::PostalService
)

    if item.destination !=
       service.destination

        return false
    end

    weight =
        billable_weight(item)

    if weight >
       service.max_weight_g

        return false
    end

    if item.length_mm >
       service.max_length_mm

        return false
    end

    if item.width_mm >
       service.max_width_mm

        return false
    end

    if item.height_mm >
       service.max_height_mm

        return false
    end

    return true
end

# ================================================================
# SERVICE PRICE
# ================================================================

function calculate_postage(
    item::PostalItem,
    service::PostalService
)

    weight =
        billable_weight(item)

    additional_blocks =
        max(
            0,
            ceil(
                (weight - 500.0) /
                500.0
            )
        )

    price =
        service.base_price +
        additional_blocks *
        service.price_per_500g

    return round(
        price,
        digits=2
    )
end

# ================================================================
# GET AVAILABLE SERVICES
# ================================================================

function available_services(
    session::CustomerSession
)

    if session.postal_item === nothing

        return PostalService[]
    end

    item =
        session.postal_item

    return [
        service
        for service in SERVICES
        if service_available(
            item,
            service
        )
    ]
end

# ================================================================
# SELECT SERVICE
# ================================================================

function select_service!(
    session::CustomerSession,
    service_id::String
)

    if session.postal_item === nothing

        session.status = ERROR
        session.error_message =
            "Postal item has not been configured."

        return false
    end

    matches =
        filter(
            s -> s.id == service_id,
            SERVICES
        )

    if isempty(matches)

        session.status = ERROR
        session.error_message =
            "Unknown postal service."

        return false
    end

    service =
        first(matches)

    if !service_available(
        session.postal_item,
        service
    )

        session.status = ERROR
        session.error_message =
            "Selected service is not available for this item."

        return false
    end

    session.selected_service =
        service

    postage =
        calculate_postage(
            session.postal_item,
            service
        )

    add_line!(
        session.basket,
        service.name,
        postage
    )

    session.status =
        BASKET_READY

    return true
end

# ================================================================
# ADD PACKAGING
# ================================================================

function add_packaging!(
    session::CustomerSession,
    inventory::KioskInventory,
    product_id::String,
    quantity::Int = 1
)

    if quantity <= 0

        return false
    end

    if !haskey(
        inventory.products,
        product_id
    )

        session.status = ERROR
        session.error_message =
            "Packaging product not found."

        return false
    end

    product =
        inventory.products[
            product_id
        ]

    if product.stock <
       quantity

        session.status = ERROR
        session.error_message =
            "Insufficient packaging stock."

        return false
    end

    product.stock -=
        quantity

    inventory.products[
        product_id
    ] = product

    add_line!(
        session.basket,
        product.name,
        product.price,
        quantity
    )

    session.status =
        BASKET_READY

    return true
end

# ================================================================
# OPTIONAL SERVICES
# ================================================================

function add_signature!(
    session::CustomerSession
)

    if session.selected_service === nothing
        return false
    end

    service =
        session.selected_service

    if service.signature
        return true
    end

    surcharge = 2.00

    add_line!(
        session.basket,
        "Signature service",
        surcharge
    )

    return true
end

# ================================================================
# DISCOUNT ENGINE
# ================================================================

function apply_discount!(
    session::CustomerSession,
    percentage::Float64
)

    percentage =
        clamp(
            percentage,
            0.0,
            100.0
        )

    session.basket.discount =
        session.basket.subtotal *
        percentage /
        100.0

    recalculate!(
        session.basket
    )
end

# ================================================================
# PAYMENT ENGINE
# ================================================================

function begin_payment!(
    session::CustomerSession
)

    if session.basket.total <= 0

        session.status = ERROR
        session.error_message =
            "Basket total is invalid."

        return false
    end

    session.status =
        PAYMENT_PROCESSING

    session.payment_status =
        PAYMENT_PENDING

    return true
end


function process_payment!(
    session::CustomerSession,
    approved::Bool = true
)

    if session.status !=
       PAYMENT_PROCESSING

        return false
    end

    if approved

        session.payment_status =
            PAYMENT_AUTHORISED

        session.payment_reference =
            "PAY-" *
            string(
                uuid4()
            )

        return true

    else

        session.payment_status =
            PAYMENT_DECLINED

        session.status =
            ERROR

        session.error_message =
            "Payment declined."

        return false
    end
end

# ================================================================
# RECEIPT GENERATION
# ================================================================

function generate_receipt!(
    session::CustomerSession
)

    if session.payment_status !=
       PAYMENT_AUTHORISED

        return ""
    end

    session.receipt_number =
        "PP-" *
        Dates.format(
            now(),
            "yyyymmdd-HHMMSS"
        ) *
        "-" *
        uppercase(
            string(
                rand(
                    'A':'Z',
                    4
                )
            )
        )

    io =
        IOBuffer()

    println(
        io,
        "================================"
    )

    println(
        io,
        "         POSTPOINT"
    )

    println(
        io,
        "      POSTAGE RECEIPT"
    )

    println(
        io,
        "================================"
    )

    println(
        io,
        "Receipt: ",
        session.receipt_number
    )

    println(
        io,
        "Date: ",
        now()
    )

    println(
        io,
        "Transaction: ",
        session.id
    )

    println(
        io,
        "--------------------------------"
    )

    for line in
        session.basket.lines

        println(
            io,
            rpad(
                line.description,
                24
            ),
            " £",
            @sprintf(
                "%.2f",
                line_total(line)
            )
        )
    end

    println(
        io,
        "--------------------------------"
    )

    println(
        io,
        "Subtotal: £",
        @sprintf(
            "%.2f",
            session.basket.subtotal
        )
    )

    println(
        io,
        "Discount: £",
        @sprintf(
            "%.2f",
            session.basket.discount
        )
    )

    println(
        io,
        "Total:    £",
        @sprintf(
            "%.2f",
            session.basket.total
        )
    )

    println(
        io,
        "--------------------------------"
    )

    if session.selected_service !== nothing

        service =
            session.selected_service

        println(
            io,
            "Service: ",
            service.name
        )

        println(
            io,
            "Tracking: ",
            service.tracking
        )

        println(
            io,
            "Estimated delivery: ",
            service.estimated_days
        )
    end

    println(
        io,
        "--------------------------------"
    )

    println(
        io,
        "Payment: AUTHORISED"
    )

    println(
        io,
        "Reference: ",
        session.payment_reference
    )

    println(
        io,
        "================================"
    )

    return String(
        take!(
            io
        )
    )
end

# ================================================================
# COMPLETE TRANSACTION
# ================================================================

function complete_transaction!(
    session::CustomerSession
)

    if session.payment_status !=
       PAYMENT_AUTHORISED

        session.status =
            ERROR

        session.error_message =
            "Cannot complete unpaid transaction."

        return false
    end

    session.status =
        COMPLETED

    return true
end

# ================================================================
# CANCEL TRANSACTION
# ================================================================

function cancel_transaction!(
    session::CustomerSession
)

    session.status =
        CANCELLED

    session.payment_status =
        PAYMENT_CANCELLED

    return true
end

# ================================================================
# KIOSK HOME STATE
# ================================================================

function kiosk_home()

    println()
    println("╔══════════════════════════════════════════╗")
    println("║              POSTPOINT KIOSK            ║")
    println("╠══════════════════════════════════════════╣")
    println("║                                          ║")
    println("║       SEND A LETTER OR PARCEL            ║")
    println("║                                          ║")
    println("║       BUY PACKAGING                      ║")
    println("║                                          ║")
    println("║       TRACKING SERVICES                  ║")
    println("║                                          ║")
    println("╚══════════════════════════════════════════╝")
end

# ================================================================
# KIOSK STATUS
# ================================================================

function kiosk_status(
    inventory::KioskInventory
)

    println()
    println(
        "--------------- KIOSK STATUS ---------------"
    )

    println(
        "Receipt paper: ",
        inventory.receipt_roll_remaining
    )

    println(
        "Internal paper stock: ",
        inventory.paper_remaining
    )

    println()
    println(
        "Packaging inventory:"
    )

    for product in
        values(
            inventory.products
        )

        println(
            "  ",
            rpad(
                product.name,
                28
            ),
            " ",
            product.stock
        )
    end
end

# ================================================================
# FULL DEMONSTRATION TRANSACTION
# ================================================================

function demo_transaction()

    println()
    println(
        "=============================================="
    )

    println(
        " POSTPOINT TRANSACTION ENGINE"
    )

    println(
        "=============================================="
    )

    inventory =
        create_inventory()

    # ------------------------------------------------------------
    # Customer arrives
    # ------------------------------------------------------------

    session =
        new_session()

    println(
        "Session: ",
        session.id
    )

    # ------------------------------------------------------------
    # Destination
    # ------------------------------------------------------------

    set_destination!(
        session,
        UK
    )

    # ------------------------------------------------------------
    # Parcel measurement
    # ------------------------------------------------------------

    configure_item!(
        session,

        PARCEL,

        1250.0,    # grams

        300.0,     # length

        200.0,     # width

        120.0      # height
    )

    # ------------------------------------------------------------
    # Show available services
    # ------------------------------------------------------------

    println()
    println(
        "AVAILABLE SERVICES:"
    )

    for service in
        available_services(
            session
        )

        price =
            calculate_postage(
                session.postal_item,
                service
            )

        println(
            "  ",
            service.id,
            " | ",
            service.name,
            " | £",
            @sprintf(
                "%.2f",
                price
            ),
            " | ",
            service.estimated_days
        )
    end

    # ------------------------------------------------------------
    # Customer chooses tracked service
    # ------------------------------------------------------------

    select_service!(
        session,
        "UK-TRACKED"
    )

    # ------------------------------------------------------------
    # Customer buys packaging
    # ------------------------------------------------------------

    add_packaging!(
        session,
        inventory,
        "BOX-S"
    )

    # ------------------------------------------------------------
    # Recalculate
    # ------------------------------------------------------------

    recalculate!(
        session.basket
    )

    println()
    println(
        "BASKET"
    )

    for line in
        session.basket.lines

        println(
            "  ",
            line.description,
            " × ",
            line.quantity,
            " = £",
            @sprintf(
                "%.2f",
                line_total(line)
            )
        )
    end

    println(
        "TOTAL: £",
        @sprintf(
            "%.2f",
            session.basket.total
        )
    )

    # ------------------------------------------------------------
    # Payment
    # ------------------------------------------------------------

    begin_payment!(
        session
    )

    println()
    println(
        "Processing payment..."
    )

    process_payment!(
        session,
        true
    )

    # ------------------------------------------------------------
    # Complete
    # ------------------------------------------------------------

    complete_transaction!(
        session
    )

    # ------------------------------------------------------------
    # Receipt
    # ------------------------------------------------------------

    receipt =
        generate_receipt!(
            session
        )

    println()
    println(
        receipt
    )

    println(
        "TRANSACTION STATUS: ",
        session.status
    )

    return session
end

# ================================================================
# START KIOSK
# ================================================================

kiosk_home()

session =
    demo_transaction()

inventory =
    create_inventory()

kiosk_status(
    inventory
)
```


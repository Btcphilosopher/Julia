############################################################
# US E-COMMERCE WAREHOUSE ROBOT
# Julia simulation
#
# CAMERA
#   ↓
# OBJECT DETECTION
#   ↓
# SKU / PRODUCT UNDERSTANDING
#   ↓
# INVENTORY DATABASE
#   ↓
# PICK LOCATION
#   ↓
# PATH PLANNING
#   ↓
# ROBOTIC ARM
#   ↓
# CUSTOMER TOTE
#   ↓
# VISION VERIFICATION
############################################################

using Random
using LinearAlgebra

############################################################
# 1. WAREHOUSE DATA STRUCTURES
############################################################

struct Product
    sku::String
    name::String
    category::String
    weight_kg::Float64
end

struct ShelfLocation
    aisle::Int
    bay::Int
    level::Int
    x::Float64
    y::Float64
    z::Float64
end

struct InventoryItem
    product::Product
    location::ShelfLocation
    quantity::Int
end

struct Tote
    id::String
    destination::String
    capacity::Int
    items::Vector{String}
end

struct PickDecision
    sku::String
    product::Product
    source::ShelfLocation
    tote::Tote
    confidence::Float64
end


############################################################
# 2. PRODUCTS
############################################################

products = Dict(

    "A1001" => Product(
        "A1001",
        "Wireless Headphones",
        "ELECTRONICS",
        0.35
    ),

    "B2001" => Product(
        "B2001",
        "Stainless Steel Water Bottle",
        "HOME",
        0.55
    ),

    "C3001" => Product(
        "C3001",
        "Running Shoes",
        "FOOTWEAR",
        0.85
    ),

    "D4001" => Product(
        "D4001",
        "USB-C Cable",
        "ELECTRONICS",
        0.12
    ),

    "E5001" => Product(
        "E5001",
        "Coffee Grinder",
        "KITCHEN",
        1.25
    )
)


############################################################
# 3. WAREHOUSE INVENTORY
############################################################

inventory = Dict(

    "A1001" => InventoryItem(
        products["A1001"],
        ShelfLocation(12, 4, 2, 24.0, 8.0, 2.0),
        37
    ),

    "B2001" => InventoryItem(
        products["B2001"],
        ShelfLocation(7, 3, 1, 14.0, 6.0, 1.0),
        52
    ),

    "C3001" => InventoryItem(
        products["C3001"],
        ShelfLocation(15, 2, 3, 30.0, 4.0, 3.0),
        18
    ),

    "D4001" => InventoryItem(
        products["D4001"],
        ShelfLocation(4, 7, 1, 8.0, 14.0, 1.0),
        94
    ),

    "E5001" => InventoryItem(
        products["E5001"],
        ShelfLocation(20, 2, 2, 40.0, 4.0, 2.0),
        11
    )
)


############################################################
# 4. CUSTOMER ORDER
############################################################

order = [
    "A1001",
    "D4001",
    "B2001"
]

tote = Tote(
    "TOTE-84721",
    "PACK-STATION-14",
    20,
    String[]
)


############################################################
# 5. CAMERA
############################################################

function camera_scan(sku::String)

    println()
    println("CAMERA")
    println("--------------------------------")

    println("Scanning shelf...")

    sleep(0.2)

    println("Object detected.")

    return sku
end


############################################################
# 6. COMPUTER VISION
############################################################

function identify_product(
    detected_sku::String,
    products
)

    println()
    println("VISION SYSTEM")
    println("--------------------------------")

    if haskey(products, detected_sku)

        product = products[detected_sku]

        println(
            "Detected product: ",
            product.name
        )

        println(
            "SKU: ",
            product.sku
        )

        println(
            "Category: ",
            product.category
        )

        return product, 0.98
    end

    println("UNKNOWN OBJECT")

    return nothing, 0.0
end


############################################################
# 7. INVENTORY UNDERSTANDING
############################################################

function locate_product(
    sku::String,
    inventory
)

    println()
    println("INVENTORY SYSTEM")
    println("--------------------------------")

    if !haskey(inventory, sku)

        println("SKU NOT FOUND")

        return nothing
    end

    item = inventory[sku]

    if item.quantity <= 0

        println("OUT OF STOCK")

        return nothing
    end

    println(
        "Inventory quantity: ",
        item.quantity
    )

    println(
        "Aisle: ",
        item.location.aisle
    )

    println(
        "Bay: ",
        item.location.bay
    )

    println(
        "Level: ",
        item.location.level
    )

    return item
end


############################################################
# 8. WAREHOUSE COORDINATE SYSTEM
############################################################

function warehouse_distance(
    a::ShelfLocation,
    b::ShelfLocation
)

    return sqrt(
        (a.x - b.x)^2 +
        (a.y - b.y)^2 +
        (a.z - b.z)^2
    )
end


############################################################
# 9. ROBOT NAVIGATION
############################################################

robot_position = ShelfLocation(
    1,
    1,
    1,
    2.0,
    2.0,
    1.0
)


function navigate_to(
    robot::ShelfLocation,
    target::ShelfLocation
)

    println()
    println("MOBILE ROBOT")
    println("--------------------------------")

    distance = warehouse_distance(
        robot,
        target
    )

    println(
        "Current position: ",
        (robot.x, robot.y, robot.z)
    )

    println(
        "Target position: ",
        (target.x, target.y, target.z)
    )

    println(
        "Distance: ",
        round(distance, digits=2),
        " m"
    )

    println("Planning collision-free path...")

    sleep(0.3)

    println("Path calculated.")

    println("Driving to aisle ", target.aisle)

    sleep(0.3)

    println("Arrived at pick zone.")

    return target
end


############################################################
# 10. ROBOTIC ARM
############################################################

function reach_for_item(
    location::ShelfLocation
)

    println()
    println("ROBOTIC ARM")
    println("--------------------------------")

    println(
        "Target coordinates: ",
        (location.x, location.y, location.z)
    )

    println("Calculating arm trajectory...")

    sleep(0.2)

    println("Moving shoulder joint...")
    println("Moving elbow joint...")
    println("Moving wrist...")
    println("Aligning gripper...")

    sleep(0.3)

    println("GRIPPER CLOSED")

    return true
end


############################################################
# 11. PICK VERIFICATION
############################################################

function verify_pick(
    product::Product
)

    println()
    println("VISION VERIFICATION")
    println("--------------------------------")

    println(
        "Checking picked object..."
    )

    sleep(0.2)

    println(
        "Expected: ",
        product.name
    )

    println(
        "Detected: ",
        product.name
    )

    println("MATCH CONFIRMED")

    return true
end


############################################################
# 12. MOVE TO TOTE
############################################################

function place_in_tote(
    product::Product,
    tote::Tote
)

    println()
    println("TOTE PLACEMENT")
    println("--------------------------------")

    if length(tote.items) >= tote.capacity

        println("TOTE FULL")

        return false
    end

    println(
        "Moving ",
        product.name,
        " to ",
        tote.id
    )

    sleep(0.3)

    println("Aligning with tote...")

    println("GRIPPER OPEN")

    push!(
        tote.items,
        product.sku
    )

    println(
        "PLACED: ",
        product.name
    )

    return true
end


############################################################
# 13. UPDATE INVENTORY
############################################################

function decrement_inventory!(
    sku::String,
    inventory
)

    item = inventory[sku]

    inventory[sku] = InventoryItem(
        item.product,
        item.location,
        item.quantity - 1
    )

    println(
        "Inventory updated: ",
        item.quantity - 1,
        " remaining"
    )
end


############################################################
# 14. COMPLETE PICK OPERATION
############################################################

function pick_item!(
    sku::String,
    inventory,
    products,
    tote,
    robot_position
)

    println()
    println("================================================")
    println("NEW PICK TASK: ", sku)
    println("================================================")

    ########################################################
    # CAMERA
    ########################################################

    detected = camera_scan(sku)

    ########################################################
    # VISION
    ########################################################

    product, confidence =
        identify_product(
            detected,
            products
        )

    if product === nothing
        println("TASK FAILED")
        return robot_position
    end

    ########################################################
    # INVENTORY
    ########################################################

    item = locate_product(
        sku,
        inventory
    )

    if item === nothing
        println("TASK FAILED")
        return robot_position
    end

    ########################################################
    # NAVIGATION
    ########################################################

    target = navigate_to(
        robot_position,
        item.location
    )

    ########################################################
    # PICK
    ########################################################

    success = reach_for_item(
        target
    )

    if !success
        println("PICK FAILED")
        return robot_position
    end

    ########################################################
    # VERIFY
    ########################################################

    verified = verify_pick(
        product
    )

    if !verified
        println("VERIFICATION FAILED")
        return robot_position
    end

    ########################################################
    # TOTE
    ########################################################

    placed = place_in_tote(
        product,
        tote
    )

    if !placed
        return robot_position
    end

    ########################################################
    # INVENTORY
    ########################################################

    decrement_inventory!(
        sku,
        inventory
    )

    println()
    println("TASK COMPLETE")

    return target
end


############################################################
# 15. RUN THE WAREHOUSE
############################################################

println()
println("################################################")
println("# US E-COMMERCE ROBOTIC FULFILLMENT SYSTEM")
println("################################################")

for sku in order

    robot_position =
        pick_item!(
            sku,
            inventory,
            products,
            tote,
            robot_position
        )

end


############################################################
# 16. FINAL STATE
############################################################

println()
println("================================================")
println("ORDER COMPLETE")
println("================================================")

println(
    "Tote: ",
    tote.id
)

println(
    "Destination: ",
    tote.destination
)

println(
    "Items: ",
    tote.items
)

println()

println("WAREHOUSE ROBOT: READY FOR NEXT ORDER")

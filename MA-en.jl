# ============================================================
# ROBOTIC AWARENESS SYSTEM
# ============================================================
#
# Sensor → Perception → Tracking → Risk Assessment
#        → Prediction → Decision
#
# Designed as a foundation for autonomous robotics.
# ============================================================

using LinearAlgebra
using Statistics

# ------------------------------------------------------------
# OBJECT REPRESENTATION
# ------------------------------------------------------------

struct DetectedObject
    name::String

    # Position [x, y, z] in metres
    position::Vector{Float64}

    # Velocity [vx, vy, vz] in metres/second
    velocity::Vector{Float64}

    # Approximate physical radius
    size::Float64
end


# ------------------------------------------------------------
# ROBOT REPRESENTATION
# ------------------------------------------------------------

struct Robot
    position::Vector{Float64}
    velocity::Vector{Float64}

    # Maximum distance at which the robot maintains awareness
    awareness_range::Float64

    # Minimum safe distance
    safety_distance::Float64
end


# ------------------------------------------------------------
# DISTANCE CALCULATION
# ------------------------------------------------------------

function distance(a::Vector{Float64},
                  b::Vector{Float64})

    return norm(a - b)
end


# ------------------------------------------------------------
# RELATIVE MOTION
# ------------------------------------------------------------

function relative_velocity(robot_position,
                           robot_velocity,
                           object_position,
                           object_velocity)

    relative_position = object_position - robot_position
    relative_velocity = object_velocity - robot_velocity

    d = norm(relative_position)

    if d < 1e-6
        return 0.0
    end

    direction = relative_position / d

    # Positive value means the object is approaching
    return -dot(relative_velocity, direction)
end


# ------------------------------------------------------------
# RISK ASSESSMENT
# ------------------------------------------------------------

function assess_risk(robot::Robot,
                      object::DetectedObject)

    d = distance(robot.position,
                 object.position)

    approaching_speed =
        relative_velocity(
            robot.position,
            robot.velocity,
            object.position,
            object.velocity
        )

    # Immediate danger
    if d <= robot.safety_distance

        return "DANGER"

    # Object is approaching rapidly
    elseif d <= robot.safety_distance * 2 &&
           approaching_speed > 0.2

        return "CAUTION"

    # Object is inside awareness zone
    elseif d <= robot.awareness_range

        return "MONITOR"

    else

        return "SAFE"
    end
end


# ------------------------------------------------------------
# TIME TO COLLISION
# ------------------------------------------------------------

function time_to_collision(robot::Robot,
                           object::DetectedObject)

    d = distance(robot.position,
                 object.position)

    approach_speed =
        relative_velocity(
            robot.position,
            robot.velocity,
            object.position,
            object.velocity
        )

    # Object is not approaching
    if approach_speed <= 0

        return Inf
    end

    return d / approach_speed
end


# ------------------------------------------------------------
# ENVIRONMENT SCANNING
# ------------------------------------------------------------

function scan_environment(robot::Robot,
                          objects)

    println("========================================")
    println("       ROBOTIC AWARENESS SYSTEM")
    println("========================================")

    for object in objects

        d = distance(
            robot.position,
            object.position
        )

        # Ignore objects outside awareness range
        if d > robot.awareness_range
            continue
        end

        risk = assess_risk(
            robot,
            object
        )

        ttc = time_to_collision(
            robot,
            object
        )

        println()
        println("Object: ", object.name)

        println(
            "Distance: ",
            round(d, digits=2),
            " m"
        )

        println(
            "Risk level: ",
            risk
        )

        if isfinite(ttc)

            println(
                "Time to collision: ",
                round(ttc, digits=2),
                " seconds"
            )

        else

            println(
                "Time to collision: none"
            )
        end

        # Robot response recommendation
        if risk == "DANGER"

            println(
                "ACTION: EMERGENCY STOP"
            )

        elseif risk == "CAUTION"

            println(
                "ACTION: REDUCE SPEED"
            )

        elseif risk == "MONITOR"

            println(
                "ACTION: CONTINUE MONITORING"
            )

        else

            println(
                "ACTION: CONTINUE"
            )
        end
    end
end


# ------------------------------------------------------------
# EXAMPLE ROBOT
# ------------------------------------------------------------

robot = Robot(

    # Position
    [0.0, 0.0, 0.0],

    # Velocity
    [0.5, 0.0, 0.0],

    # Awareness range
    20.0,

    # Safety distance
    2.0
)


# ------------------------------------------------------------
# EXAMPLE ENVIRONMENT
# ------------------------------------------------------------

objects = [

    DetectedObject(
        "Human",
        [5.0, 1.0, 0.0],
        [-0.5, 0.0, 0.0],
        0.4
    ),

    DetectedObject(
        "Robot",
        [10.0, -2.0, 0.0],
        [-1.0, 0.2, 0.0],
        0.8
    ),

    DetectedObject(
        "Box",
        [15.0, 3.0, 0.0],
        [0.0, 0.0, 0.0],
        0.5
    ),

    DetectedObject(
        "Wall",
        [30.0, 0.0, 0.0],
        [0.0, 0.0, 0.0],
        5.0
    )
]


# ------------------------------------------------------------
# RUN AWARENESS SYSTEM
# ------------------------------------------------------------

scan_environment(
    robot,
    objects
)



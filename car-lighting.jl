config = LightingConfig(
    deg2rad(15.0),
    deg2rad(8.0),

    30.0,
    250.0,

    0.15,
    1.0,

    deg2rad(20.0),
    deg2rad(10.0),
    1.5,

    0.45,
    0.65,

    24,

    0.02
)


state = VehicleLightingState(
    28.0,              # 101 km/h
    deg2rad(7.0),       # steering
    0.12,               # yaw rate

    0.014,              # road curvature
    0.01,               # gradient

    0.02,               # ambient light

    0.05,               # rain
    0.0,                # fog

    0.0,

    0.0,
    0.0,
    0.5
)


traffic = RoadUser[
    RoadUser(
        160.0,
        -4.0,
        0.0,
        :oncoming
    ),

    RoadUser(
        90.0,
        2.0,
        -5.0,
        :ahead
    ),

    RoadUser(
        65.0,
        -5.0,
        0.0,
        :pedestrian
    )
]


command =
    optimise_lighting(
        config,
        state,
        traffic
    )


println("Lighting mode: ",
        command.mode)

println(
    "Beam angle: ",
    rad2deg(command.horizontal_angle),
    "°"
)

println(
    "Beam range: ",
    round(command.range),
    " m"
)

println(
    "Intensity: ",
    round(command.intensity, 2)
)

println(
    "Matrix zones: ",
    command.matrix_zones
)

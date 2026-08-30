```julia
# ================================================================
# ASTRA-JL
# Julia Telescope Engineering & Observation Simulator
#
# Models:
#   Aperture
#   Focal length
#   Focal ratio
#   Eyepiece
#   Magnification
#   Field of view
#   Diffraction limit
#   Light gathering
#   Limiting magnitude
#   Star visibility
#   Simple sky simulation
# ================================================================

using Printf
using Random
using Statistics

# ================================================================
# CONSTANTS
# ================================================================

const ARCSEC_PER_RAD = 206265.0
const REFERENCE_APERTURE_MM = 7.0

# ================================================================
# TELESCOPE
# ================================================================

mutable struct Telescope

    name::String

    aperture_mm::Float64

    focal_length_mm::Float64

    central_obstruction_mm::Float64

    optical_efficiency::Float64

    eyepiece_mm::Float64

    eyepiece_afov_deg::Float64

    tracking::Bool

    tracking_error_arcsec::Float64
end

# ================================================================
# STAR
# ================================================================

struct Star

    name::String

    right_ascension_deg::Float64

    declination_deg::Float64

    magnitude::Float64

    colour_index::Float64
end

# ================================================================
# OPTICAL CALCULATIONS
# ================================================================

function focal_ratio(
    telescope::Telescope
)

    return (
        telescope.focal_length_mm /
        telescope.aperture_mm
    )
end

# ------------------------------------------------
# Magnification
# ------------------------------------------------

function magnification(
    telescope::Telescope
)

    return (
        telescope.focal_length_mm /
        telescope.eyepiece_mm
    )
end

# ------------------------------------------------
# True field of view
# ------------------------------------------------

function true_field_of_view(
    telescope::Telescope
)

    return (
        telescope.eyepiece_afov_deg /
        magnification(telescope)
    )
end

# ------------------------------------------------
# Diffraction limit
#
# Dawes-style approximation:
#
# Resolution ≈ 116 / aperture(mm)
#
# ------------------------------------------------

function diffraction_limit_arcsec(
    telescope::Telescope
)

    effective_aperture =
        sqrt(
            telescope.aperture_mm^2 -
            telescope.central_obstruction_mm^2
        )

    return (
        116.0 /
        effective_aperture
    )
end

# ------------------------------------------------
# Rayleigh criterion
# ------------------------------------------------

function rayleigh_limit_arcsec(
    telescope::Telescope
)

    effective_aperture =
        sqrt(
            telescope.aperture_mm^2 -
            telescope.central_obstruction_mm^2
        )

    return (
        138.0 /
        effective_aperture
    )
end

# ------------------------------------------------
# Light gathering power
# ------------------------------------------------

function light_gathering_power(
    telescope::Telescope
)

    effective_area =
        telescope.aperture_mm^2 -
        telescope.central_obstruction_mm^2

    reference_area =
        REFERENCE_APERTURE_MM^2

    return (
        effective_area /
        reference_area
    )
end

# ------------------------------------------------
# Limiting magnitude
# ------------------------------------------------

function limiting_magnitude(
    telescope::Telescope
)

    D =
        telescope.aperture_mm

    # Approximate visual limiting magnitude
    # for dark-sky conditions.

    return (
        2.0 +
        5.0 *
        log10(D)
    )
end

# ================================================================
# OPTICAL PERFORMANCE
# ================================================================

function optical_performance(
    telescope::Telescope
)

    aperture =
        telescope.aperture_mm

    obstruction =
        telescope.central_obstruction_mm

    effective_area =
        π / 4 *
        (
            aperture^2 -
            obstruction^2
        )

    throughput =
        effective_area *
        telescope.optical_efficiency

    return throughput
end

# ================================================================
# AIRY DISK
#
# Approximate angular radius:
#
# θ = 1.22 λ / D
# ================================================================

function airy_disk_arcsec(
    telescope::Telescope,
    wavelength_nm::Float64 = 550.0
)

    wavelength =
        wavelength_nm *
        1e-9

    diameter =
        telescope.aperture_mm *
        1e-3

    theta =
        1.22 *
        wavelength /
        diameter

    return (
        theta *
        ARCSEC_PER_RAD
    )
end

# ================================================================
# ATMOSPHERIC SEEING
# ================================================================

function observed_resolution(
    telescope::Telescope,
    seeing_arcsec::Float64
)

    diffraction =
        diffraction_limit_arcsec(
            telescope
        )

    tracking =
        telescope.tracking ?
        telescope.tracking_error_arcsec :
        0.0

    # Combine independent resolution effects.

    return sqrt(
        diffraction^2 +
        seeing_arcsec^2 +
        tracking^2
    )
end

# ================================================================
# STAR VISIBILITY
# ================================================================

function star_visible(
    telescope::Telescope,
    star::Star,
    sky_limiting_magnitude::Float64
)

    telescope_limit =
        limiting_magnitude(
            telescope
        )

    effective_limit =
        min(
            telescope_limit,
            sky_limiting_magnitude
        )

    return star.magnitude <=
           effective_limit
end

# ================================================================
# STAR ANGULAR SEPARATION
# ================================================================

function angular_separation(
    a::Star,
    b::Star
)

    ra1 =
        deg2rad(
            a.right_ascension_deg
        )

    ra2 =
        deg2rad(
            b.right_ascension_deg
        )

    dec1 =
        deg2rad(
            a.declination_deg
        )

    dec2 =
        deg2rad(
            b.declination_deg
        )

    cosθ =
        sin(dec1) *
        sin(dec2) +
        cos(dec1) *
        cos(dec2) *
        cos(ra1 - ra2)

    θ =
        acos(
            clamp(
                cosθ,
                -1.0,
                1.0
            )
        )

    return rad2deg(θ)
end

# ================================================================
# DOUBLE STAR RESOLUTION
# ================================================================

function can_resolve_double(
    telescope::Telescope,
    separation_arcsec::Float64,
    seeing_arcsec::Float64
)

    resolution =
        observed_resolution(
            telescope,
            seeing_arcsec
        )

    return separation_arcsec >
           resolution
end

# ================================================================
# TELESCOPE REPORT
# ================================================================

function report(
    telescope::Telescope
)

    println()
    println(
        "=========================================================="
    )

    println(
        "                 ASTRA-JL"
    )

    println(
        "          TELESCOPE PERFORMANCE REPORT"
    )

    println(
        "=========================================================="
    )

    println(
        "Instrument:             ",
        telescope.name
    )

    @printf(
        "Aperture:               %.1f mm\n",
        telescope.aperture_mm
    )

    @printf(
        "Focal length:           %.1f mm\n",
        telescope.focal_length_mm
    )

    @printf(
        "Focal ratio:            f/%.2f\n",
        focal_ratio(telescope)
    )

    @printf(
        "Central obstruction:    %.1f mm\n",
        telescope.central_obstruction_mm
    )

    @printf(
        "Eyepiece:               %.1f mm\n",
        telescope.eyepiece_mm
    )

    @printf(
        "Magnification:          %.1fx\n",
        magnification(telescope)
    )

    @printf(
        "True field:             %.3f°\n",
        true_field_of_view(telescope)
    )

    @printf(
        "Diffraction limit:      %.3f arcsec\n",
        diffraction_limit_arcsec(
            telescope
        )
    )

    @printf(
        "Rayleigh limit:         %.3f arcsec\n",
        rayleigh_limit_arcsec(
            telescope
        )
    )

    @printf(
        "Airy disk:              %.3f arcsec\n",
        airy_disk_arcsec(
            telescope
        )
    )

    @printf(
        "Light gathering:        %.1fx naked eye\n",
        light_gathering_power(
            telescope
        )
    )

    @printf(
        "Limiting magnitude:     %.2f\n",
        limiting_magnitude(
            telescope
        )
    )

    @printf(
        "Optical throughput:     %.1f mm² equivalent\n",
        optical_performance(
            telescope
        )
    )

    println(
        "Tracking:               ",
        telescope.tracking
    )

    println(
        "=========================================================="
    )
end

# ================================================================
# EYEPIECE SWEEP
# ================================================================

function eyepiece_sweep(
    telescope::Telescope,
    eyepieces
)

    println()
    println(
        "EYEPIECE PERFORMANCE"
    )

    println(
        "----------------------------------------------------------"
    )

    @printf(
        "%10s %12s %14s\n",
        "Eyepiece",
        "Magnification",
        "FOV"
    )

    for eyepiece in
        eyepieces

        telescope.eyepiece_mm =
            eyepiece

        @printf(
            "%8.1f mm %10.1fx %12.3f°\n",

            eyepiece,

            magnification(
                telescope
            ),

            true_field_of_view(
                telescope
            )
        )
    end

    println(
        "----------------------------------------------------------"
    )
end

# ================================================================
# APERTURE OPTIMISATION
# ================================================================

function aperture_sweep(
    focal_ratio_value::Float64,
    apertures
)

    println()
    println(
        "APERTURE PERFORMANCE"
    )

    println(
        "----------------------------------------------------------"
    )

    @printf(
        "%10s %12s %14s %14s\n",
        "Aperture",
        "Focal Length",
        "Resolution",
        "Light Gain"
    )

    for aperture in
        apertures

        focal_length =
            aperture *
            focal_ratio_value

        telescope =
            Telescope(

                "Simulation",

                aperture,

                focal_length,

                0.0,

                0.90,

                20.0,

                68.0,

                true,

                0.5
            )

        @printf(
            "%8.0f mm %10.0f mm %10.3f arcsec %10.1fx\n",

            aperture,

            focal_length,

            diffraction_limit_arcsec(
                telescope
            ),

            light_gathering_power(
                telescope
            )
        )
    end

    println(
        "----------------------------------------------------------"
    )
end

# ================================================================
# SIMPLE SKY SIMULATOR
# ================================================================

function generate_stars(
    n::Int
)

    stars =
        Star[]

    for i in 1:n

        push!(
            stars,

            Star(

                "STAR-" *
                string(i),

                rand() *
                360.0,

                rand() *
                180.0 -
                90.0,

                rand() *
                8.0,

                rand() *
                2.0 -
                0.5
            )
        )
    end

    return stars
end

# ================================================================
# OBSERVATION SIMULATOR
# ================================================================

function observe_sky(
    telescope::Telescope,
    stars,
    sky_limiting_magnitude
)

    visible =
        filter(
            star ->
                star_visible(
                    telescope,
                    star,
                    sky_limiting_magnitude
                ),
            stars
        )

    println()
    println(
        "SKY OBSERVATION"
    )

    println(
        "----------------------------------------------------------"
    )

    println(
        "Stars simulated:       ",
        length(stars)
    )

    println(
        "Stars visible:         ",
        length(visible)
    )

    @printf(
        "Sky limit:             %.2f mag\n",
        sky_limiting_magnitude
    )

    println()

    for star in
        visible[
            1:min(
                20,
                length(visible)
            )
        ]

        @printf(
            "%-10s RA=%7.2f° DEC=%7.2f° MAG=%5.2f\n",

            star.name,

            star.right_ascension_deg,

            star.declination_deg,

            star.magnitude
        )
    end
end

# ================================================================
# EXAMPLE TELESCOPE
# ================================================================

telescope =
    Telescope(

        "ASTRA 250",

        250.0,       # aperture

        2000.0,      # focal length

        50.0,        # obstruction

        0.88,        # optical efficiency

        20.0,        # eyepiece

        68.0,        # eyepiece AFOV

        true,        # tracking

        0.35         # tracking error
    )

# ================================================================
# RUN
# ================================================================

println(
    "Initialising ASTRA-JL..."
)

report(
    telescope
)

# ------------------------------------------------
# Test atmospheric conditions
# ------------------------------------------------

println()

for seeing in
    [0.5, 1.0, 2.0, 3.0]

    @printf(
        "Seeing %.1f arcsec → observed resolution %.3f arcsec\n",

        seeing,

        observed_resolution(
            telescope,
            seeing
        )
    )
end

# ------------------------------------------------
# Eyepiece optimisation
# ------------------------------------------------

eyepiece_sweep(

    telescope,

    [
        5.0,
        10.0,
        15.0,
        20.0,
        25.0,
        30.0,
        40.0
    ]
)

# ------------------------------------------------
# Aperture study
# ------------------------------------------------

aperture_sweep(

    8.0,

    [
        80.0,
        100.0,
        150.0,
        200.0,
        250.0,
        300.0,
        400.0,
        500.0
    ]
)

# ------------------------------------------------
# Generate artificial star field
# ------------------------------------------------

stars =
    generate_stars(
        1000
    )

# ------------------------------------------------
# Observe sky
# ------------------------------------------------

observe_sky(

    telescope,

    stars,

    6.5
)

# ================================================================
# DOUBLE STAR TEST
# ================================================================

println()
println(
    "DOUBLE-STAR RESOLUTION TEST"
)

for separation in
    [0.25, 0.50, 0.75, 1.0, 1.5, 2.0]

    resolved =
        can_resolve_double(
            telescope,
            separation,
            1.0
        )

    @printf(
        "Separation %.2f arcsec → %s\n",
        separation,
        resolved ?
        "RESOLVED" :
        "NOT RESOLVED"
    )
end

println()
println(
    "ASTRA-JL simulation complete."
)
```


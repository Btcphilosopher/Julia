Julia computational-imaging core

Here's the sort of engine I'd build:

module PixelDensityEngine

using LinearAlgebra
using Statistics
using Images
using ImageFiltering

export PixelAnalysis,
       analyze_pixels,
       denoise_image,
       sharpen_image,
       super_resolve,
       improve_image

struct PixelAnalysis
    width::Int
    height::Int
    megapixels::Float64
    mean_luminance::Float64
    noise_level::Float64
    edge_density::Float64
    detail_score::Float64
end

function luminance(img)
    return 0.2126 .* Float64.(channelview(img)[1,:,:]) .+
           0.7152 .* Float64.(channelview(img)[2,:,:]) .+
           0.0722 .* Float64.(channelview(img)[3,:,:])
end

function analyze_pixels(img)

    h, w = size(img)[1:2]

    y = luminance(img)

    mean_y = mean(y)

    # Local high-frequency energy
    kernel_x = [-1.0 0.0 1.0]

    kernel_y = [-1.0, 0.0, 1.0]

    gx = imfilter(y, kernel_x)
    gy = imfilter(y, kernel_y)

    gradient = sqrt.(gx.^2 .+ gy.^2)

    edge_density =
        mean(gradient .> quantile(vec(gradient), 0.75))

    # Estimate noise from high-frequency residual
    smooth = imfilter(
        y,
        Kernel.gaussian(1.0)
    )

    residual = y .- smooth

    noise = std(residual)

    # Detail metric
    detail =
        mean(abs.(gradient)) /
        (noise + 1e-6)

    PixelAnalysis(
        w,
        h,
        (w * h) / 1_000_000,
        mean_y,
        noise,
        edge_density,
        detail
    )
end


function denoise_image(img; strength=0.35)

    # Gaussian estimate of low-frequency structure
    blurred = imfilter(
        img,
        Kernel.gaussian(strength)
    )

    # Preserve high-frequency structure
    residual = img .- blurred

    # Soft threshold
    threshold = strength * 0.02

    cleaned = blurred .+
        sign.(residual) .*
        max.(abs.(residual) .- threshold, 0)

    return clamp.(cleaned, 0, 1)
end


function sharpen_image(img; amount=0.7)

    blurred = imfilter(
        img,
        Kernel.gaussian(1.0)
    )

    high_frequency = img .- blurred

    sharpened =
        img .+
        amount .* high_frequency

    return clamp.(sharpened, 0, 1)
end


function super_resolve(img; scale=2)

    # Initial interpolation
    enlarged = imresize(
        img,
        ratio=scale
    )

    # Recover high-frequency structure
    smooth = imfilter(
        enlarged,
        Kernel.gaussian(1.0)
    )

    detail = enlarged .- smooth

    reconstructed =
        enlarged .+
        0.45 .* detail

    return clamp.(reconstructed, 0, 1)
end


function improve_image(
    img;
    scale=2,
    denoise_strength=0.25,
    sharpen_amount=0.55
)

    # 1. Analyse sensor output
    analysis = analyze_pixels(img)

    # 2. Noise reduction
    cleaned = denoise_image(
        img;
        strength=denoise_strength
    )

    # 3. Computational resolution increase
    enlarged = super_resolve(
        cleaned;
        scale=scale
    )

    # 4. Restore fine detail
    final = sharpen_image(
        enlarged;
        amount=sharpen_amount
    )

    return final, analysis
end

end

But I'd go considerably further than this for the iPhone system you're describing.

Multi-frame computational pixel density

The really interesting part is that you don't need to accept the information contained in one exposure.

Suppose the sensor is 48 MP.

Instead of:

48 MP frame
     ↓
JPEG

you could capture a short burst:

Frame 1  ──┐
Frame 2  ──┤
Frame 3  ──┼──→ Julia reconstruction → ~effective 96 MP detail
Frame 4  ──┤
Frame 5  ──┘

The frames contain slightly different sub-pixel samples because of natural hand movement and/or deliberate micro-shifts.

Julia can estimate those shifts:

struct FrameShift
    dx::Float64
    dy::Float64
end

function estimate_shift(reference, frame)

    best_error = Inf
    best_dx = 0.0
    best_dy = 0.0

    for dx in -2.0:0.25:2.0
        for dy in -2.0:0.25:2.0

            shifted = circshift(
                frame,
                (round(Int, dy), round(Int, dx))
            )

            error =
                mean((reference .- shifted).^2)

            if error < best_error
                best_error = error
                best_dx = dx
                best_dy = dy
            end
        end
    end

    FrameShift(
        best_dx,
        best_dy
    )
end

Then combine the aligned frames:

function fuse_frames(frames, shifts)

    reference = frames[1]

    accumulated =
        zeros(Float64, size(reference))

    weights =
        zeros(Float64, size(reference))

    for (frame, shift) in zip(frames, shifts)

        aligned =
            circshift(
                frame,
                (
                    round(Int, shift.dy),
                    round(Int, shift.dx)
                )
            )

        accumulated .+= aligned
        weights .+= 1.0
    end

    result =
        accumulated ./ max.(weights, 1e-6)

    return result
end

That gives you real information aggregation, rather than simply taking a 12 MP image and stretching it to 48 MP.

Even better: sensor-aware reconstruction

I'd have the Swift side send Julia metadata such as:

struct CameraFrameMetadata: Codable {
    let width: Int
    let height: Int
    let iso: Double
    let exposureSeconds: Double
    let lensPosition: Double
    let focalLength: Double
    let digitalZoom: Double
    let motionMagnitude: Double
    let ambientLux: Double
}

Julia could then dynamically determine how aggressively to reconstruct the image:

function reconstruction_strategy(
    iso,
    motion,
    brightness,
    zoom
)

    if motion > 0.75
        return :single_frame_fast

    elseif iso > 1600
        return :noise_aware

    elseif zoom > 2.0
        return :super_resolution

    elseif brightness > 0.7
        return :high_detail

    else
        return :balanced
    end
end

So the camera becomes adaptive:

                  CAMERA SCENE
                       │
          ┌────────────┼────────────┐
          ↓            ↓            ↓
       Motion        Light        Zoom
          │            │            │
          └────────────┼────────────┘
                       ↓
                Julia Analysis
                       ↓
       ┌───────────────┼───────────────┐
       ↓               ↓               ↓
    Single          Multi-frame     Super-res
    capture           fusion        reconstruction
       │               │               │
       └───────────────┼───────────────┘
                       ↓
                 Detail Engine
                       ↓
                 Final Photograph
                 

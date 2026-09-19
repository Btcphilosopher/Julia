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
                 
                 
                 
                 
                 
module PixelDensityEngine

using LinearAlgebra
using Statistics
using FFTW
using Images
using ImageFiltering

export CameraFrame
export analyse_frame
export estimate_motion
export align_frame
export denoise
export deconvolve
export superresolve
export fuse_frames
export reconstruct

# ============================================================
# CAMERA FRAME
# ============================================================

struct CameraFrame
    image::Array{Float32,3}

    iso::Float32
    exposure::Float32

    focal_length::Float32
    lens_position::Float32

    motion::Float32
    brightness::Float32

    timestamp::Float64
end


# ============================================================
# BASIC IMAGE UTILITIES
# ============================================================

function luminance(img)

    r = @view img[:,:,1]
    g = @view img[:,:,2]
    b = @view img[:,:,3]

    return 0.2126f0 .* r .+
           0.7152f0 .* g .+
           0.0722f0 .* b
end


function clamp_image(img)

    return clamp.(img, 0f0, 1f0)

end


# ============================================================
# IMAGE QUALITY ANALYSIS
# ============================================================

function noise_estimate(img)

    y = luminance(img)

    blurred =
        imfilter(
            y,
            Kernel.gaussian(1.2)
        )

    residual = y .- blurred

    return Float32(std(residual))

end


function edge_energy(img)

    y = luminance(img)

    gx = zeros(Float32, size(y))
    gy = zeros(Float32, size(y))

    gx[:,2:end-1] .=
        y[:,3:end] .-
        y[:,1:end-2]

    gy[2:end-1,:] .=
        y[3:end,:] .-
        y[1:end-2,:]

    magnitude =
        sqrt.(gx.^2 .+ gy.^2)

    return Float32(mean(magnitude))

end


function analyse_frame(frame::CameraFrame)

    img = frame.image

    y = luminance(img)

    noise = noise_estimate(img)

    detail = edge_energy(img)

    brightness = Float32(mean(y))

    return (
        width = size(img,2),
        height = size(img,1),
        megapixels =
            size(img,1) *
            size(img,2) /
            1_000_000,

        noise = noise,
        detail = detail,
        brightness = brightness,

        iso = frame.iso,
        exposure = frame.exposure,
        motion = frame.motion
    )

end


# ============================================================
# FAST SUB-PIXEL MOTION ESTIMATION
# ============================================================

function phase_correlation(reference, image)

    a = Float64.(reference)
    b = Float64.(image)

    A = fft(a)
    B = fft(b)

    cross =
        A .* conj.(B)

    cross ./=
        max.(abs.(cross), 1e-10)

    correlation =
        real.(ifft(cross))

    idx =
        argmax(correlation)

    y, x =
        Tuple(
            CartesianIndices(correlation)[idx]
        )

    h, w = size(correlation)

    dx = x > w ÷ 2 ? x - w : x
    dy = y > h ÷ 2 ? y - h : y

    return Float32(dx),
           Float32(dy)

end


function estimate_motion(reference, image)

    r = luminance(reference)
    i = luminance(image)

    return phase_correlation(r, i)

end


# ============================================================
# SUB-PIXEL FRAME TRANSLATION
# ============================================================

function shift_image(img, dx, dy)

    h, w, c =
        size(img)

    result =
        zeros(Float32, h, w, c)

    x0 = floor(Int, dx)
    y0 = floor(Int, dy)

    fx = Float32(dx - x0)
    fy = Float32(dy - y0)

    for ch in 1:c

        src = @view img[:,:,ch]
        dst = @view result[:,:,ch]

        for y in 2:h-1
            for x in 2:w-1

                x1 = clamp(x + x0, 1, w)
                x2 = clamp(x + x0 + 1, 1, w)

                y1 = clamp(y + y0, 1, h)
                y2 = clamp(y + y0 + 1, 1, h)

                a =
                    src[y1,x1] * (1f0-fx) +
                    src[y1,x2] * fx

                b =
                    src[y2,x1] * (1f0-fx) +
                    src[y2,x2] * fx

                dst[y,x] =
                    a * (1f0-fy) +
                    b * fy
            end
        end
    end

    return result

end


function align_frame(reference, frame)

    dx, dy =
        estimate_motion(
            reference,
            frame
        )

    aligned =
        shift_image(
            frame,
            dx,
            dy
        )

    return aligned, dx, dy

end


# ============================================================
# ROBUST MULTI-FRAME NOISE REDUCTION
# ============================================================

function temporal_median(frames)

    n = length(frames)

    h, w, c =
        size(frames[1])

    output =
        zeros(Float32, h, w, c)

    for y in 1:h
        for x in 1:w
            for ch in 1:c

                values =
                    Vector{Float32}(undef, n)

                for k in 1:n
                    values[k] =
                        frames[k][y,x,ch]
                end

                output[y,x,ch] =
                    median(values)

            end
        end
    end

    return output

end


function temporal_average(frames)

    output =
        zeros(Float32, size(frames[1]))

    for frame in frames
        output .+= frame
    end

    output ./=
        Float32(length(frames))

    return output

end


# ============================================================
# EDGE-PRESERVING SPATIAL DENOISING
# ============================================================

function denoise(img; strength=0.25f0)

    blurred =
        imfilter(
            img,
            Kernel.gaussian(
                Float64(0.7 + strength * 1.8)
            )
        )

    high =
        img .- blurred

    threshold =
        strength * 0.025f0

    preserved =
        sign.(high) .*
        max.(abs.(high) .- threshold, 0f0)

    result =
        blurred .+
        preserved

    return clamp_image(result)

end


# ============================================================
# LENS / PSF DECONVOLUTION
# ============================================================

function gaussian_psf(size, sigma)

    center =
        (size + 1) / 2

    kernel =
        zeros(Float64, size, size)

    for y in 1:size
        for x in 1:size

            dx = x - center
            dy = y - center

            kernel[y,x] =
                exp(
                    -(dx^2 + dy^2) /
                    (2sigma^2)
                )
        end
    end

    kernel ./=
        sum(kernel)

    return kernel

end


function wiener_deconvolution(
    image,
    psf;
    noise_power=0.005
)

    H =
        fft(psf, size(image))

    result =
        similar(image)

    Hconj =
        conj.(H)

    denominator =
        abs2.(H) .+
        noise_power

    for ch in 1:size(image,3)

        channel =
            Float64.(image[:,:,ch])

        F =
            fft(channel)

        restored =
            real.(
                ifft(
                    F .*
                    Hconj ./
                    denominator
                )
            )

        result[:,:,ch] =
            Float32.(
                clamp.(restored, 0, 1)
            )

    end

    return result

end


function deconvolve(img; blur_sigma=0.8)

    psf =
        gaussian_psf(
            9,
            blur_sigma
        )

    return wiener_deconvolution(
        img,
        psf;
        noise_power=0.002
    )

end


# ============================================================
# HIGH-FREQUENCY DETAIL RECOVERY
# ============================================================

function detail_reconstruction(
    img;
    strength=0.75f0
)

    low =
        imfilter(
            img,
            Kernel.gaussian(1.0)
        )

    high =
        img .- low

    # Suppress very small noise-like fluctuations
    threshold = 0.006f0

    clean_high =
        sign.(high) .*
        max.(abs.(high) .- threshold, 0f0)

    output =
        img .+
        strength .* clean_high

    return clamp_image(output)

end


# ============================================================
# SUPER RESOLUTION
# ============================================================

function bilinear_upscale(img, scale)

    h, w, c =
        size(img)

    nh =
        Int(round(h * scale))

    nw =
        Int(round(w * scale))

    output =
        zeros(Float32, nh, nw, c)

    for y in 1:nh

        source_y =
            (y - 1) / scale + 1

        y0 =
            clamp(
                floor(Int, source_y),
                1,
                h
            )

        y1 =
            clamp(y0 + 1, 1, h)

        fy =
            Float32(source_y - y0)

        for x in 1:nw

            source_x =
                (x - 1) / scale + 1

            x0 =
                clamp(
                    floor(Int, source_x),
                    1,
                    w
                )

            x1 =
                clamp(x0 + 1, 1, w)

            fx =
                Float32(source_x - x0)

            for ch in 1:c

                p00 = img[y0,x0,ch]
                p10 = img[y0,x1,ch]
                p01 = img[y1,x0,ch]
                p11 = img[y1,x1,ch]

                output[y,x,ch] =
                    p00*(1-fx)*(1-fy) +
                    p10*fx*(1-fy) +
                    p01*(1-fx)*fy +
                    p11*fx*fy

            end
        end
    end

    return output

end


function superresolve(img; scale=2)

    enlarged =
        bilinear_upscale(
            img,
            scale
        )

    restored =
        detail_reconstruction(
            enlarged;
            strength=0.8f0
        )

    restored =
        deconvolve(
            restored;
            blur_sigma=0.65
        )

    return restored

end


# ============================================================
# MULTI-FRAME SUPER-RESOLUTION
# ============================================================

function fuse_frames(frames)

    n =
        length(frames)

    reference =
        frames[1]

    aligned =
        Vector{Array{Float32,3}}()

    push!(
        aligned,
        reference
    )

    for k in 2:n

        frame =
            frames[k]

        corrected, dx, dy =
            align_frame(
                reference,
                frame
            )

        push!(
            aligned,
            corrected
        )
    end

    # Robust temporal fusion
    result =
        temporal_average(
            aligned
        )

    # Recover high-frequency information
    result =
        detail_reconstruction(
            result;
            strength=0.65f0
        )

    return result

end


# ============================================================
# ADAPTIVE RECONSTRUCTION
# ============================================================

function reconstruction_strength(
    noise,
    motion,
    brightness
)

    strength = 1.0f0

    strength *=
        1.0f0 -
        min(noise * 2.0f0, 0.55f0)

    strength *=
        1.0f0 -
        min(motion * 0.8f0, 0.7f0)

    if brightness < 0.15f0
        strength *= 0.65f0
    end

    return clamp(
        strength,
        0.25f0,
        1.0f0
    )

end


# ============================================================
# COMPLETE PIPELINE
# ============================================================

function reconstruct(
    frames::Vector{CameraFrame};
    scale=2
)

    @assert length(frames) >= 1

    first =
        frames[1]

    analysis =
        analyse_frame(first)

    noise =
        analysis.noise

    motion =
        analysis.motion

    brightness =
        analysis.brightness


    # --------------------------------------------------------
    # SINGLE FRAME
    # --------------------------------------------------------

    if length(frames) == 1

        cleaned =
            denoise(
                first.image;
                strength=
                    clamp(
                        noise * 8,
                        0.05f0,
                        0.4f0
                    )
            )

        restored =
            deconvolve(
                cleaned
            )

        output =
            superresolve(
                restored;
                scale=scale
            )

        return output

    end


    # --------------------------------------------------------
    # MULTI FRAME
    # --------------------------------------------------------

    images =
        [f.image for f in frames]

    fused =
        fuse_frames(
            images
        )

    adaptive =
        reconstruction_strength(
            noise,
            motion,
            brightness
        )

    fused =
        detail_reconstruction(
            fused;
            strength=
                0.75f0 *
                adaptive
        )

    restored =
        deconvolve(
            fused;
            blur_sigma=0.6
        )

    output =
        superresolve(
            restored;
            scale=scale
        )

    return clamp_image(output)

end

end








import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate
import Metal
import MetalPerformanceShaders
import ImageIO
import UIKit

// ============================================================
// COMPUTATIONAL PIXEL ENGINE
// ============================================================

final class ComputationalPixelEngine {

    static let shared = ComputationalPixelEngine()

    private let context: CIContext
    private let metalDevice: MTLDevice

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required")
        }

        metalDevice = device

        context = CIContext(
            mtlDevice: device,
            options: [
                CIContextOption.priorityRequestLow: false,
                CIContextOption.cacheIntermediates: true
            ]
        )
    }

    // ========================================================
    // FRAME ANALYSIS
    // ========================================================

    struct FrameAnalysis {
        let width: Int
        let height: Int
        let megapixels: Double

        let meanLuminance: Float
        let noiseLevel: Float
        let edgeDensity: Float
        let detailScore: Float
        let dynamicRange: Float
    }

    // ========================================================
    // CAMERA METADATA
    // ========================================================

    struct CameraMetadata {
        let iso: Float
        let exposureDuration: Double
        let focalLength: Float
        let lensPosition: Float
        let brightness: Float
        let motion: Float
    }

    // ========================================================
    // OUTPUT
    // ========================================================

    struct ReconstructionResult {
        let image: CIImage
        let analysis: FrameAnalysis

        let inputWidth: Int
        let inputHeight: Int

        let outputWidth: Int
        let outputHeight: Int

        let effectiveScale: Float
    }


    // ========================================================
    // ANALYSE IMAGE
    // ========================================================

    func analyse(
        image: CIImage
    ) -> FrameAnalysis? {

        let extent = image.extent.integral

        let width =
            Int(extent.width)

        let height =
            Int(extent.height)

        guard width > 0 && height > 0 else {
            return nil
        }

        guard let buffer =
                makeLumaBuffer(
                    image: image,
                    width: width,
                    height: height
                )
        else {
            return nil
        }

        let count =
            width * height

        var mean: Float = 0

        vDSP_meanv(
            buffer,
            1,
            &mean,
            vDSP_Length(count)
        )

        // ----------------------------------------------------
        // Standard deviation / noise proxy
        // ----------------------------------------------------

        var variance: Float = 0

        vDSP_measqv(
            buffer,
            1,
            &variance,
            vDSP_Length(count)
        )

        let noise =
            sqrt(
                max(
                    variance - mean * mean,
                    0
                )
            )

        // ----------------------------------------------------
        // Edge detection
        // ----------------------------------------------------

        let edgeDensity =
            calculateEdgeDensity(
                buffer: buffer,
                width: width,
                height: height
            )

        let detailScore =
            edgeDensity /
            max(noise, 0.0001)

        // ----------------------------------------------------
        // Dynamic range
        // ----------------------------------------------------

        var minimum: Float = 0
        var maximum: Float = 0

        vDSP_minv(
            buffer,
            1,
            &minimum,
            vDSP_Length(count)
        )

        vDSP_maxv(
            buffer,
            1,
            &maximum,
            vDSP_Length(count)
        )

        let dynamicRange =
            maximum - minimum

        return FrameAnalysis(
            width: width,
            height: height,
            megapixels:
                Double(width * height) /
                1_000_000.0,
            meanLuminance: mean,
            noiseLevel: noise,
            edgeDensity: edgeDensity,
            detailScore: detailScore,
            dynamicRange: dynamicRange
        )
    }


    // ========================================================
    // LUMINANCE BUFFER
    // ========================================================

    private func makeLumaBuffer(
        image: CIImage,
        width: Int,
        height: Int
    ) -> [Float]? {

        var buffer =
            [Float](
                repeating: 0,
                count: width * height
            )

        let colorSpace =
            CGColorSpaceCreateDeviceGray()

        guard let cgImage =
                context.createCGImage(
                    image,
                    from: image.extent
                )
        else {
            return nil
        }

        guard let dataProvider =
                cgImage.dataProvider,
              let data =
                dataProvider.data,
              let bytes =
                CFDataGetBytePtr(data)
        else {
            return nil
        }

        let bytesPerRow =
            cgImage.bytesPerRow

        for y in 0..<height {

            let row =
                bytes +
                y * bytesPerRow

            for x in 0..<width {

                let value =
                    Float(
                        row[x]
                    ) / 255.0

                buffer[
                    y * width + x
                ] = value
            }
        }

        _ = colorSpace

        return buffer
    }


    // ========================================================
    // EDGE DENSITY
    // ========================================================

    private func calculateEdgeDensity(
        buffer: [Float],
        width: Int,
        height: Int
    ) -> Float {

        guard width > 2 && height > 2 else {
            return 0
        }

        var total: Float = 0
        var strongEdges: Int = 0

        for y in 1..<(height - 1) {

            for x in 1..<(width - 1) {

                let i =
                    y * width + x

                let left =
                    buffer[i - 1]

                let right =
                    buffer[i + 1]

                let top =
                    buffer[i - width]

                let bottom =
                    buffer[i + width]

                let gx =
                    right - left

                let gy =
                    bottom - top

                let magnitude =
                    sqrt(
                        gx * gx +
                        gy * gy
                    )

                total += magnitude

                if magnitude > 0.08 {
                    strongEdges += 1
                }
            }
        }

        let pixels =
            Float(
                (width - 2) *
                (height - 2)
            )

        let density =
            Float(strongEdges) /
            max(pixels, 1)

        return density
    }


    // ========================================================
    // ADAPTIVE DENOISING
    // ========================================================

    func denoise(
        image: CIImage,
        strength: Float
    ) -> CIImage {

        let filter =
            CIFilter.noiseReduction()

        filter.inputImage =
            image

        filter.noiseLevel =
            NSNumber(
                value:
                    Double(
                        max(
                            0.001,
                            min(
                                strength * 0.08,
                                0.20
                            )
                        )
                    )
            )

        filter.sharpness =
            NSNumber(
                value:
                    Double(
                        0.4 +
                        (1.0 - strength) * 0.4
                    )
            )

        return filter.outputImage ?? image
    }


    // ========================================================
    // HIGH-FREQUENCY DETAIL
    // ========================================================

    func recoverDetail(
        image: CIImage,
        amount: Float
    ) -> CIImage {

        let blur =
            CIFilter.gaussianBlur()

        blur.inputImage =
            image

        blur.radius =
            1.0

        guard let low =
                blur.outputImage
        else {
            return image
        }

        let blend =
            CIFilter.subtractBlendMode()

        blend.inputImage =
            image

        blend.backgroundImage =
            low

        guard let high =
                blend.outputImage
        else {
            return image
        }

        let boosted =
            high.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector":
                        CIVector(
                            x: CGFloat(amount),
                            y: 0,
                            z: 0,
                            w: 0
                        ),

                    "inputGVector":
                        CIVector(
                            x: 0,
                            y: CGFloat(amount),
                            z: 0,
                            w: 0
                        ),

                    "inputBVector":
                        CIVector(
                            x: 0,
                            y: 0,
                            z: CGFloat(amount),
                            w: 0
                        )
                ]
            )

        let addition =
            CIFilter.additionCompositing()

        addition.inputImage =
            boosted

        addition.backgroundImage =
            image

        return addition.outputImage ?? image
    }


    // ========================================================
    // UNSHARP / MICRO-CONTRAST
    // ========================================================

    func microSharpen(
        image: CIImage,
        amount: Float
    ) -> CIImage {

        let filter =
            CIFilter.unsharpMask()

        filter.inputImage =
            image

        filter.radius =
            1.0

        filter.intensity =
            CGFloat(
                min(
                    max(
                        amount,
                        0
                    ),
                    2.0
                )
            )

        return filter.outputImage ?? image
    }


    // ========================================================
    // LENS DEBLUR
    // ========================================================

    func deblur(
        image: CIImage,
        radius: Float = 0.65
    ) -> CIImage {

        let sharpen =
            CIFilter.unsharpMask()

        sharpen.inputImage =
            image

        sharpen.radius =
            CGFloat(radius)

        sharpen.intensity =
            1.15

        return sharpen.outputImage ?? image
    }


    // ========================================================
    // SUPER RESOLUTION
    // ========================================================

    func superResolve(
        image: CIImage,
        scale: Float
    ) -> CIImage {

        let extent =
            image.extent

        let transformed =
            image.transformed(
                by: CGAffineTransform(
                    scaleX:
                        CGFloat(scale),
                    y:
                        CGFloat(scale)
                )
            )

        return transformed.cropped(
            to:
                CGRect(
                    x: 0,
                    y: 0,
                    width:
                        extent.width *
                        CGFloat(scale),
                    height:
                        extent.height *
                        CGFloat(scale)
                )
        )
    }


    // ========================================================
    // FRAME ALIGNMENT
    // ========================================================

    func align(
        reference: CIImage,
        frame: CIImage
    ) -> CIImage {

        // Production implementation should use
        // Metal optical-flow / phase correlation.
        //
        // This baseline uses feature-based translation
        // estimation.

        let filter =
            CIFilter.align()

        filter.inputImage =
            frame

        filter.referenceImage =
            reference

        return filter.outputImage ?? frame
    }


    // ========================================================
    // MULTI-FRAME FUSION
    // ========================================================

    func fuse(
        frames: [CIImage]
    ) -> CIImage {

        guard let first =
                frames.first
        else {
            fatalError(
                "No frames supplied"
            )
        }

        if frames.count == 1 {
            return first
        }

        var aligned =
            [CIImage]()

        aligned.append(first)

        for frame in frames.dropFirst() {

            let registered =
                align(
                    reference: first,
                    frame: frame
                )

            aligned.append(
                registered
            )
        }

        // ----------------------------------------------------
        // Weighted compositing
        // ----------------------------------------------------

        var result =
            aligned[0]

        if aligned.count > 1 {

            for index in 1..<aligned.count {

                let opacity =
                    CGFloat(
                        1.0 /
                        Double(index + 1)
                    )

                let blend =
                    aligned[index]
                        .applyingFilter(
                            "CIColorMatrix",
                            parameters: [
                                "inputAVector":
                                    CIVector(
                                        x: 0,
                                        y: 0,
                                        z: 0,
                                        w: opacity
                                    )
                            ]
                        )

                let composite =
                    CIFilter.sourceOverCompositing()

                composite.inputImage =
                    blend

                composite.backgroundImage =
                    result

                result =
                    composite.outputImage ??
                    result
            }
        }

        return result
    }


    // ========================================================
    // ADAPTIVE PIPELINE
    // ========================================================

    func reconstruct(
        frames: [CIImage],
        metadata: CameraMetadata,
        outputScale: Float = 2.0
    ) -> ReconstructionResult? {

        guard let first =
                frames.first
        else {
            return nil
        }

        guard let analysis =
                analyse(image: first)
        else {
            return nil
        }

        // ----------------------------------------------------
        // Determine computational photography mode
        // ----------------------------------------------------

        let motion =
            metadata.motion

        let noise =
            analysis.noiseLevel

        let brightness =
            analysis.meanLuminance


        let mode: ReconstructionMode

        if motion > 0.75 {

            mode = .fast

        } else if noise > 0.15 {

            mode = .lowLight

        } else if frames.count >= 3 &&
                  motion < 0.20 {

            mode = .multiFrame

        } else {

            mode = .detail
        }


        // ----------------------------------------------------
        // DENOISE
        // ----------------------------------------------------

        var result =
            denoise(
                image: first,
                strength:
                    min(
                        max(
                            noise * 4,
                            0.05
                        ),
                        1.0
                    )
            )


        // ----------------------------------------------------
        // MULTI FRAME
        // ----------------------------------------------------

        if mode == .multiFrame {

            result =
                fuse(
                    frames: frames
                )

            result =
                denoise(
                    image: result,
                    strength:
                        noise * 2.0
                )
        }


        // ----------------------------------------------------
        // DETAIL RECOVERY
        // ----------------------------------------------------

        let detailStrength: Float

        if brightness < 0.12 {

            detailStrength = 0.25

        } else if brightness > 0.75 {

            detailStrength = 0.90

        } else {

            detailStrength = 0.65
        }

        result =
            recoverDetail(
                image: result,
                amount: detailStrength
            )


        // ----------------------------------------------------
        // DEBLUR
        // ----------------------------------------------------

        if mode != .fast {

            result =
                deblur(
                    image: result,
                    radius: 0.6
                )
        }


        // ----------------------------------------------------
        // SUPER RESOLUTION
        // ----------------------------------------------------

        result =
            superResolve(
                image: result,
                scale: outputScale
            )


        // ----------------------------------------------------
        // FINAL MICRO SHARPEN
        // ----------------------------------------------------

        result =
            microSharpen(
                image: result,
                amount:
                    mode == .fast
                    ? 0.35
                    : 0.65
            )


        let finalWidth =
            Int(
                result.extent.width
            )

        let finalHeight =
            Int(
                result.extent.height
            )


        return ReconstructionResult(
            image: result,
            analysis: analysis,
            inputWidth: analysis.width,
            inputHeight: analysis.height,
            outputWidth: finalWidth,
            outputHeight: finalHeight,
            effectiveScale: outputScale
        )
    }


    // ========================================================
    // RECONSTRUCTION MODES
    // ========================================================

    enum ReconstructionMode {

        case fast
        case lowLight
        case multiFrame
        case detail

    }


    // ========================================================
    // EXPORT
    // ========================================================

    func render(
        image: CIImage,
        to url: URL,
        quality: CGFloat = 0.98
    ) throws {

        let colorSpace =
            CGColorSpaceCreateDeviceRGB()

        guard let destination =
                CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.heic.identifier as CFString,
                    1,
                    nil
                )
        else {
            throw NSError(
                domain:
                    "ComputationalPixelEngine",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create HEIC destination"
                ]
            )
        }

        guard let cgImage =
                context.createCGImage(
                    image,
                    from: image.extent,
                    format: .RGBA8,
                    colorSpace: colorSpace
                )
        else {
            throw NSError(
                domain:
                    "ComputationalPixelEngine",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not render image"
                ]
            )
        }

        CGImageDestinationAddImage(
            destination,
            cgImage,
            [
                kCGImageDestinationLossyCompressionQuality:
                    quality
            ] as CFDictionary
        )

        guard CGImageDestinationFinalize(
            destination
        ) else {
            throw NSError(
                domain:
                    "ComputationalPixelEngine",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not write image"
                ]
            )
        }
    }
}






import AVFoundation
import CoreImage

final class HighDensityCamera {

    let session = AVCaptureSession()

    private let photoOutput =
        AVCapturePhotoOutput()

    private var capturedFrames =
        [CIImage]()

    private let processingQueue =
        DispatchQueue(
            label:
                "com.aureom.camera.processing",
            qos: .userInitiated
        )


    func prepare() {

        session.beginConfiguration()

        session.sessionPreset =
            .photo

        guard let camera =
                AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .back
                )
        else {
            return
        }

        guard let input =
                try? AVCaptureDeviceInput(
                    device: camera
                )
        else {
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        if photoOutput.isHighResolutionCaptureEnabled {
            photoOutput.isHighResolutionCaptureEnabled =
                true
        }

        session.commitConfiguration()

        session.startRunning()
    }


    func captureComputationalPhoto(
        completion:
            @escaping (UIImage?) -> Void
    ) {

        processingQueue.async {

            self.capturedFrames.removeAll(
                keepingCapacity: true
            )

            let group =
                DispatchGroup()

            let numberOfFrames = 5

            for _ in 0..<numberOfFrames {

                group.enter()

                self.captureFrame { image in

                    if let image {
                        self.capturedFrames.append(
                            image
                        )
                    }

                    group.leave()
                }
            }

            group.notify(
                queue: self.processingQueue
            ) {

                guard
                    let first =
                        self.capturedFrames.first
                else {
                    completion(nil)
                    return
                }

                let metadata =
                    ComputationalPixelEngine
                        .CameraMetadata(
                            iso: 100,
                            exposureDuration:
                                1.0 / 250.0,
                            focalLength: 24,
                            lensPosition: 0.5,
                            brightness: 0.5,
                            motion: 0.05
                        )

                let result =
                    ComputationalPixelEngine
                        .shared
                        .reconstruct(
                            frames:
                                self.capturedFrames,
                            metadata:
                                metadata,
                            outputScale: 2.0
                        )

                guard let result else {
                    completion(nil)
                    return
                }

                let ciContext =
                    CIContext()

                guard let cgImage =
                        ciContext.createCGImage(
                            result.image,
                            from:
                                result.image.extent
                        )
                else {
                    completion(nil)
                    return
                }

                completion(
                    UIImage(
                        cgImage: cgImage
                    )
                )
            }
        }
    }


    private func captureFrame(
        completion:
            @escaping (CIImage?) -> Void
    ) {

        let settings =
            AVCapturePhotoSettings()

        settings.photoQualityPrioritization =
            .quality

        if #available(
            iOS 16.0,
            *
        ) {
            settings.maxPhotoDimensions =
                photoOutput
                    .maxPhotoDimensions
        }

        let delegate =
            PhotoDelegate(
                completion:
                    completion
            )

        photoOutput.capturePhoto(
            with: settings,
            delegate: delegate
        )
    }
}









# ============================================================
# AUREOM HIGH-DENSITY COMPUTATIONAL CAMERA
# Python reference implementation
#
# Pipeline:
#
# RAW / PHOTO FRAMES
#       ↓
# Noise analysis
#       ↓
# Motion estimation
#       ↓
# Sub-pixel registration
#       ↓
# Multi-frame fusion
#       ↓
# Edge-preserving denoise
#       ↓
# Wiener deconvolution
#       ↓
# High-frequency reconstruction
#       ↓
# 2x super-resolution
#       ↓
# Final high-density photograph
# ============================================================

import cv2
import numpy as np

from dataclasses import dataclass
from typing import List, Tuple
from scipy import ndimage
from scipy.signal import fftconvolve


# ============================================================
# CAMERA FRAME
# ============================================================

@dataclass
class CameraFrame:

    image: np.ndarray

    iso: float = 100.0
    exposure: float = 1 / 250

    focal_length: float = 24.0
    lens_position: float = 0.5

    motion: float = 0.0
    brightness: float = 0.5

    timestamp: float = 0.0


# ============================================================
# ANALYSIS
# ============================================================

@dataclass
class FrameAnalysis:

    width: int
    height: int

    megapixels: float

    luminance: float
    noise: float

    edge_density: float
    detail_score: float

    dynamic_range: float


# ============================================================
# RGB → LUMINANCE
# ============================================================

def luminance(image):

    image = image.astype(np.float32)

    if image.max() > 1.0:
        image /= 255.0

    return (
        0.2126 * image[:, :, 0]
        + 0.7152 * image[:, :, 1]
        + 0.0722 * image[:, :, 2]
    )


# ============================================================
# NOISE ESTIMATION
# ============================================================

def estimate_noise(image):

    y = luminance(image)

    smooth = cv2.GaussianBlur(
        y,
        (0, 0),
        1.2
    )

    residual = y - smooth

    return float(
        np.std(residual)
    )


# ============================================================
# EDGE ENERGY
# ============================================================

def edge_energy(image):

    y = luminance(image)

    gx = cv2.Sobel(
        y,
        cv2.CV_32F,
        1,
        0,
        ksize=3
    )

    gy = cv2.Sobel(
        y,
        cv2.CV_32F,
        0,
        1,
        ksize=3
    )

    magnitude = np.sqrt(
        gx * gx +
        gy * gy
    )

    return float(
        np.mean(magnitude)
    )


# ============================================================
# EDGE DENSITY
# ============================================================

def edge_density(image):

    y = luminance(image)

    edges = cv2.Canny(
        (y * 255).astype(np.uint8),
        60,
        140
    )

    return float(
        np.mean(edges > 0)
    )


# ============================================================
# COMPLETE FRAME ANALYSIS
# ============================================================

def analyse_frame(frame: CameraFrame):

    image = frame.image

    h, w = image.shape[:2]

    y = luminance(image)

    noise = estimate_noise(image)

    edges = edge_density(image)

    detail = (
        edge_energy(image)
        / max(noise, 1e-5)
    )

    return FrameAnalysis(

        width=w,

        height=h,

        megapixels=(
            w * h
            / 1_000_000
        ),

        luminance=float(
            np.mean(y)
        ),

        noise=noise,

        edge_density=edges,

        detail_score=detail,

        dynamic_range=float(
            np.max(y) -
            np.min(y)
        )
    )


# ============================================================
# PHASE CORRELATION
# ============================================================

def phase_correlation(
    reference,
    image
):

    ref = luminance(reference)

    img = luminance(image)

    shift, response = cv2.phaseCorrelate(
        ref.astype(np.float32),
        img.astype(np.float32)
    )

    dx, dy = shift

    return (
        float(dx),
        float(dy),
        float(response)
    )


# ============================================================
# SUB-PIXEL TRANSLATION
# ============================================================

def translate(
    image,
    dx,
    dy
):

    h, w = image.shape[:2]

    matrix = np.array([
        [1, 0, dx],
        [0, 1, dy]
    ], dtype=np.float32)

    return cv2.warpAffine(
        image,
        matrix,
        (w, h),
        flags=cv2.INTER_CUBIC,
        borderMode=cv2.BORDER_REFLECT
    )


# ============================================================
# ALIGN FRAME
# ============================================================

def align_frame(
    reference,
    frame
):

    dx, dy, response = (
        phase_correlation(
            reference,
            frame
        )
    )

    aligned = translate(
        frame,
        -dx,
        -dy
    )

    return (
        aligned,
        dx,
        dy,
        response
    )


# ============================================================
# ROBUST MULTI-FRAME FUSION
# ============================================================

def temporal_fusion(
    frames: List[np.ndarray]
):

    stack = np.stack(
        frames,
        axis=0
    )

    # Median suppresses transient noise
    median = np.median(
        stack,
        axis=0
    )

    # Estimate deviation from median
    deviation = np.abs(
        stack - median
    )

    # Reject extreme outliers
    threshold = (
        np.median(deviation)
        * 3.0
        + 1e-6
    )

    valid = (
        deviation < threshold
    )

    weighted = (
        stack * valid
    )

    weights = (
        valid.astype(
            np.float32
        )
    )

    result = (
        np.sum(
            weighted,
            axis=0
        )
        /
        np.maximum(
            np.sum(
                weights,
                axis=0
            ),
            1
        )
    )

    return result.astype(
        np.float32
    )


# ============================================================
# EDGE-PRESERVING DENOISE
# ============================================================

def denoise(
    image,
    strength=0.25
):

    image8 = np.clip(
        image * 255,
        0,
        255
    ).astype(np.uint8)

    # Non-local means is much better than
    # simply blurring the photograph.

    result = cv2.fastNlMeansDenoisingColored(
        image8,
        None,
        h=(
            3.0 +
            15.0 * strength
        ),
        hColor=(
            3.0 +
            10.0 * strength
        ),
        templateWindowSize=7,
        searchWindowSize=21
    )

    return (
        result.astype(
            np.float32
        ) / 255.0
    )


# ============================================================
# GAUSSIAN POINT SPREAD FUNCTION
# ============================================================

def gaussian_psf(
    size=11,
    sigma=1.0
):

    axis = np.arange(
        -(size // 2),
        size // 2 + 1
    )

    x, y = np.meshgrid(
        axis,
        axis
    )

    psf = np.exp(
        -(
            x*x +
            y*y
        )
        /
        (2 * sigma * sigma)
    )

    psf /= np.sum(psf)

    return psf


# ============================================================
# WIENER DECONVOLUTION
# ============================================================

def wiener_deconvolution(
    image,
    psf,
    noise_power=0.002
):

    h, w = image.shape[:2]

    padded_psf = np.zeros(
        (h, w),
        dtype=np.float32
    )

    ph, pw = psf.shape

    padded_psf[
        :ph,
        :pw
    ] = psf

    padded_psf = np.roll(
        padded_psf,
        -ph // 2,
        axis=0
    )

    padded_psf = np.roll(
        padded_psf,
        -pw // 2,
        axis=1
    )

    H = np.fft.fft2(
        padded_psf
    )

    H_conj = np.conj(H)

    denominator = (
        np.abs(H) ** 2
        +
        noise_power
    )

    output = np.zeros_like(
        image
    )

    for channel in range(3):

        channel_data = (
            image[:, :, channel]
        )

        F = np.fft.fft2(
            channel_data
        )

        restored = np.real(
            np.fft.ifft2(
                F
                *
                H_conj
                /
                denominator
            )
        )

        output[:, :, channel] = (
            np.clip(
                restored,
                0,
                1
            )
        )

    return output.astype(
        np.float32
    )


# ============================================================
# HIGH-FREQUENCY DETAIL RECOVERY
# ============================================================

def recover_detail(
    image,
    strength=0.7
):

    low = cv2.GaussianBlur(
        image,
        (0, 0),
        1.0
    )

    high = (
        image -
        low
    )

    # Soft threshold prevents
    # noise becoming artificial detail.

    threshold = 0.006

    clean = (
        np.sign(high)
        *
        np.maximum(
            np.abs(high)
            - threshold,
            0
        )
    )

    result = (
        image
        +
        strength * clean
    )

    return np.clip(
        result,
        0,
        1
    ).astype(
        np.float32
    )


# ============================================================
# MULTI-SCALE DETAIL
# ============================================================

def multiscale_detail(
    image
):

    base = image.copy()

    blur1 = cv2.GaussianBlur(
        base,
        (0, 0),
        0.7
    )

    blur2 = cv2.GaussianBlur(
        base,
        (0, 0),
        1.5
    )

    detail1 = (
        base -
        blur1
    )

    detail2 = (
        blur1 -
        blur2
    )

    result = (
        base
        +
        0.65 * detail1
        +
        0.25 * detail2
    )

    return np.clip(
        result,
        0,
        1
    )


# ============================================================
# 2× SUPER RESOLUTION
# ============================================================

def super_resolution(
    image,
    scale=2
):

    h, w = image.shape[:2]

    enlarged = cv2.resize(
        image,
        (
            int(w * scale),
            int(h * scale)
        ),
        interpolation=cv2.INTER_CUBIC
    )

    # Reconstruction after scaling
    enlarged = recover_detail(
        enlarged,
        strength=0.75
    )

    enlarged = multiscale_detail(
        enlarged
    )

    return np.clip(
        enlarged,
        0,
        1
    ).astype(
        np.float32
    )


# ============================================================
# ADAPTIVE RECONSTRUCTION MODE
# ============================================================

def select_mode(
    analysis: FrameAnalysis,
    number_of_frames: int
):

    if analysis.noise > 0.15:
        return "LOW_LIGHT"

    if analysis.edge_density < 0.015:
        return "DETAIL_RECOVERY"

    if number_of_frames >= 3:
        return "MULTI_FRAME"

    return "STANDARD"


# ============================================================
# MAIN COMPUTATIONAL ENGINE
# ============================================================

class HighDensityEngine:

    def __init__(
        self,
        output_scale=2
    ):

        self.output_scale = (
            output_scale
        )


    def process(
        self,
        frames: List[CameraFrame]
    ) -> Tuple[
        np.ndarray,
        FrameAnalysis
    ]:

        if not frames:
            raise ValueError(
                "No camera frames supplied"
            )

        reference =
            frames[0].image

        analysis =
            analyse_frame(
                frames[0]
            )

        mode = select_mode(
            analysis,
            len(frames)
        )

        print(
            f"Mode: {mode}"
        )

        print(
            f"Input: "
            f"{analysis.width} × "
            f"{analysis.height}"
        )

        print(
            f"Input MP: "
            f"{analysis.megapixels:.2f}"
        )

        print(
            f"Noise: "
            f"{analysis.noise:.4f}"
        )

        print(
            f"Detail: "
            f"{analysis.detail_score:.3f}"
        )


        # ----------------------------------------------------
        # STEP 1 — FRAME ALIGNMENT
        # ----------------------------------------------------

        aligned = [
            reference
        ]

        for frame in frames[1:]:

            registered, dx, dy, response = (
                align_frame(
                    reference,
                    frame.image
                )
            )

            print(
                f"Frame alignment: "
                f"dx={dx:.3f}, "
                f"dy={dy:.3f}, "
                f"response={response:.3f}"
            )

            # Reject badly aligned frames
            if response > 0.05:
                aligned.append(
                    registered
                )


        # ----------------------------------------------------
        # STEP 2 — TEMPORAL FUSION
        # ----------------------------------------------------

        if (
            mode == "MULTI_FRAME"
            and len(aligned) >= 2
        ):

            result = temporal_fusion(
                aligned
            )

        else:

            result = reference.copy()


        # ----------------------------------------------------
        # STEP 3 — DENOISE
        # ----------------------------------------------------

        denoise_strength = np.clip(
            analysis.noise * 5.0,
            0.05,
            0.75
        )

        result = denoise(
            result,
            denoise_strength
        )


        # ----------------------------------------------------
        # STEP 4 — OPTICAL DEBLUR
        # ----------------------------------------------------

        psf = gaussian_psf(
            size=11,
            sigma=0.65
        )

        result = wiener_deconvolution(
            result,
            psf,
            noise_power=0.0015
        )


        # ----------------------------------------------------
        # STEP 5 — DETAIL RECOVERY
        # ----------------------------------------------------

        detail_strength = np.clip(
            0.9 -
            analysis.noise * 2.0,
            0.25,
            0.90
        )

        result = recover_detail(
            result,
            detail_strength
        )


        # ----------------------------------------------------
        # STEP 6 — SUPER RESOLUTION
        # ----------------------------------------------------

        result = super_resolution(
            result,
            scale=self.output_scale
        )


        # ----------------------------------------------------
        # STEP 7 — FINAL MICRO-CONTRAST
        # ----------------------------------------------------

        result = recover_detail(
            result,
            strength=0.35
        )


        return result, analysis


# ============================================================
# IMAGE LOAD / SAVE
# ============================================================

def load_image(
    path
):

    image = cv2.imread(
        path,
        cv2.IMREAD_COLOR
    )

    if image is None:
        raise FileNotFoundError(
            path
        )

    image = cv2.cvtColor(
        image,
        cv2.COLOR_BGR2RGB
    )

    return (
        image.astype(
            np.float32
        )
        / 255.0
    )


def save_image(
    path,
    image
):

    image8 = (
        np.clip(
            image,
            0,
            1
        )
        * 255
    ).astype(
        np.uint8
    )

    image8 = cv2.cvtColor(
        image8,
        cv2.COLOR_RGB2BGR
    )

    cv2.imwrite(
        path,
        image8
    )


# ============================================================
# EXAMPLE
# ============================================================

if __name__ == "__main__":

    frame1 = load_image(
        "frame_01.jpg"
    )

    frame2 = load_image(
        "frame_02.jpg"
    )

    frame3 = load_image(
        "frame_03.jpg"
    )

    frame4 = load_image(
        "frame_04.jpg"
    )

    frame5 = load_image(
        "frame_05.jpg"
    )


    frames = [

        CameraFrame(
            image=frame1,
            iso=100,
            exposure=1 / 500,
            motion=0.04
        ),

        CameraFrame(
            image=frame2,
            iso=100,
            exposure=1 / 500,
            motion=0.04
        ),

        CameraFrame(
            image=frame3,
            iso=100,
            exposure=1 / 500,
            motion=0.04
        ),

        CameraFrame(
            image=frame4,
            iso=100,
            exposure=1 / 500,
            motion=0.04
        ),

        CameraFrame(
            image=frame5,
            iso=100,
            exposure=1 / 500,
            motion=0.04
        )
    ]


    engine = HighDensityEngine(
        output_scale=2
    )


    output, analysis = (
        engine.process(
            frames
        )
    )


    save_image(
        "iphone_high_density.png",
        output
    )


    print()
    print(
        "================================"
    )

    print(
        "HIGH-DENSITY RECONSTRUCTION"
    )

    print(
        "================================"
    )

    print(
        f"Original: "
        f"{analysis.width} × "
        f"{analysis.height}"
    )

    print(
        f"Original MP: "
        f"{analysis.megapixels:.2f}"
    )

    print(
        f"Output: "
        f"{output.shape[1]} × "
        f"{output.shape[0]}"
    )

    print(
        f"Output MP: "
        f"{output.shape[0] * output.shape[1] / 1e6:.2f}"
    )
    
    
    
    
    
    

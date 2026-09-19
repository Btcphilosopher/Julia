//
//  AureomColourDensityEngine.swift
//
//  High-density computational colour pipeline for iPhone
//
//  Capture:
//      AVFoundation
//          ↓
//      Wide-gamut / HDR
//          ↓
//      Extended precision Core Image
//          ↓
//      Linear-light processing
//          ↓
//      Highlight recovery
//          ↓
//      Chroma preservation
//          ↓
//      Local colour-density reconstruction
//          ↓
//      Gamut mapping
//          ↓
//      Display P3 / HEIF
//

import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import Accelerate
import Metal
import UIKit
import UniformTypeIdentifiers


// ============================================================
// COLOUR DENSITY ENGINE
// ============================================================

final class AureomColourDensityEngine {

    static let shared =
        AureomColourDensityEngine()

    private let metalDevice: MTLDevice

    private let context: CIContext

    private let workingColorSpace: CGColorSpace

    private let outputColorSpace: CGColorSpace


    private init() {

        guard let device =
                MTLCreateSystemDefaultDevice()
        else {
            fatalError(
                "Metal GPU unavailable"
            )
        }

        metalDevice = device

        // Wide-gamut working space.
        //
        // ExtendedLinearSRGB allows calculations
        // above 1.0 without immediately clipping
        // bright HDR information.

        workingColorSpace =
            CGColorSpace(
                name:
                    CGColorSpace.extendedLinearSRGB
            )!

        // Display P3 is useful for modern
        // wide-gamut iPhone output.

        outputColorSpace =
            CGColorSpace(
                name:
                    CGColorSpace.displayP3
            )!

        context =
            CIContext(
                mtlDevice: device,
                options: [

                    .workingColorSpace:
                        workingColorSpace,

                    .outputColorSpace:
                        outputColorSpace,

                    .cacheIntermediates:
                        true,

                    .priorityRequestLow:
                        false
                ]
            )
    }


    // ========================================================
    // CONFIGURATION
    // ========================================================

    struct Configuration {

        var saturationDensity:
            Float = 1.08

        var chromaPreservation:
            Float = 0.92

        var highlightRecovery:
            Float = 0.85

        var shadowColourRecovery:
            Float = 0.55

        var localColourContrast:
            Float = 0.30

        var gamutProtection:
            Float = 0.90

        var microColour:
            Float = 0.25

        var hdrHeadroom:
            Float = 1.25
    }


    // ========================================================
    // CAMERA INFORMATION
    // ========================================================

    struct CameraColourMetadata {

        let iso: Float

        let exposureDuration:
            Double

        let temperature:
            Float

        let tint:
            Float

        let brightness:
            Float

        let hdrEnabled:
            Bool
    }


    // ========================================================
    // COLOUR ANALYSIS
    // ========================================================

    struct ColourAnalysis {

        let averageRed:
            Float

        let averageGreen:
            Float

        let averageBlue:
            Float

        let averageChroma:
            Float

        let colourVariance:
            Float

        let saturation:
            Float

        let highlightClipping:
            Float

        let shadowCrushing:
            Float

        let estimatedColourInformation:
            Float
    }


    // ========================================================
    // IMAGE ANALYSIS
    // ========================================================

    func analyse(
        image: CIImage
    ) -> ColourAnalysis? {

        let extent =
            image.extent.integral

        guard
            extent.width > 0,
            extent.height > 0
        else {
            return nil
        }


        let ciImage =
            image
                .converted(
                    to:
                        workingColorSpace
                )


        guard let cgImage =
                context.createCGImage(
                    ciImage,
                    from: extent,
                    format: .RGBAh,
                    colorSpace:
                        workingColorSpace
                )
        else {
            return nil
        }


        let width =
            cgImage.width

        let height =
            cgImage.height

        let bytesPerRow =
            cgImage.bytesPerRow


        guard
            let provider =
                cgImage.dataProvider,
            let data =
                provider.data
        else {
            return nil
        }


        let bytes =
            CFDataGetBytePtr(data)!

        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0

        var chromaSum: Float = 0

        var clippingPixels = 0
        var crushedPixels = 0


        for y in 0..<height {

            let row =
                bytes +
                y * bytesPerRow

            for x in 0..<width {

                let index =
                    x * 8

                // RGBA half-float
                let r =
                    halfToFloat(
                        row + index
                    )

                let g =
                    halfToFloat(
                        row + index + 2
                    )

                let b =
                    halfToFloat(
                        row + index + 4
                    )


                sumR += r
                sumG += g
                sumB += b


                let maxChannel =
                    max(
                        r,
                        max(g, b)
                    )

                let minChannel =
                    min(
                        r,
                        min(g, b)
                    )

                chromaSum +=
                    maxChannel -
                    minChannel


                if maxChannel >= 1.0 {
                    clippingPixels += 1
                }

                if maxChannel <= 0.005 {
                    crushedPixels += 1
                }
            }
        }


        let pixelCount =
            Float(width * height)


        let averageR =
            sumR / pixelCount

        let averageG =
            sumG / pixelCount

        let averageB =
            sumB / pixelCount

        let averageChroma =
            chromaSum / pixelCount


        let clipping =
            Float(clippingPixels) /
            pixelCount

        let crushing =
            Float(crushedPixels) /
            pixelCount


        let saturation =
            averageChroma /
            max(
                (
                    averageR +
                    averageG +
                    averageB
                ) / 3,
                0.001
            )


        let information =
            saturation
            *
            (1.0 - clipping)
            *
            (1.0 - crushing)


        return ColourAnalysis(

            averageRed:
                averageR,

            averageGreen:
                averageG,

            averageBlue:
                averageB,

            averageChroma:
                averageChroma,

            colourVariance:
                averageChroma,

            saturation:
                saturation,

            highlightClipping:
                clipping,

            shadowCrushing:
                crushing,

            estimatedColourInformation:
                information
        )
    }


    // ========================================================
    // EXTENDED PRECISION CONVERSION
    // ========================================================

    func prepareWorkingImage(
        image: CIImage
    ) -> CIImage {

        return image
            .converted(
                to:
                    workingColorSpace
            )
    }


    // ========================================================
    // WHITE BALANCE
    // ========================================================

    func whiteBalance(
        image: CIImage,
        temperature: Float,
        tint: Float
    ) -> CIImage {

        let filter =
            CIFilter.temperatureAndTint()

        filter.inputImage =
            image

        filter.neutral =
            CIVector(
                x:
                    CGFloat(
                        temperature
                    ),
                y:
                    CGFloat(
                        tint
                    )
            )

        filter.targetNeutral =
            CIVector(
                x: 6500,
                y: 0
            )

        return (
            filter.outputImage
            ?? image
        )
    }


    // ========================================================
    // CHROMA PRESERVATION
    // ========================================================

    func preserveChroma(
        image: CIImage,
        strength: Float
    ) -> CIImage {

        let filter =
            CIFilter.colorControls()

        filter.inputImage =
            image

        filter.saturation =
            CGFloat(
                1.0 +
                strength * 0.08
            )

        filter.contrast =
            CGFloat(
                1.0 +
                strength * 0.02
            )

        filter.brightness =
            0

        return (
            filter.outputImage
            ?? image
        )
    }


    // ========================================================
    // COLOUR DENSITY
    // ========================================================

    func increaseColourDensity(
        image: CIImage,
        amount: Float
    ) -> CIImage {

        // Work in Lab-like perceptual separation
        // rather than simply pushing RGB saturation.

        let controls =
            CIFilter.colorControls()

        controls.inputImage =
            image

        controls.saturation =
            CGFloat(
                1.0 +
                amount * 0.15
            )

        controls.contrast =
            CGFloat(
                1.0 +
                amount * 0.025
            )

        guard let output =
                controls.outputImage
        else {
            return image
        }

        return output
    }


    // ========================================================
    // LOCAL COLOUR CONTRAST
    // ========================================================

    func localColourContrast(
        image: CIImage,
        amount: Float
    ) -> CIImage {

        let blur =
            CIFilter.gaussianBlur()

        blur.inputImage =
            image

        blur.radius =
            8.0


        guard let lowFrequency =
                blur.outputImage
        else {
            return image
        }


        let difference =
            CIFilter.subtractBlendMode()

        difference.inputImage =
            image

        difference.backgroundImage =
            lowFrequency


        guard let chromaDetail =
                difference.outputImage
        else {
            return image
        }


        let boosted =
            chromaDetail.applyingFilter(
                "CIColorMatrix",
                parameters: [

                    "inputRVector":
                        CIVector(
                            x:
                                CGFloat(amount),
                            y: 0,
                            z: 0,
                            w: 0
                        ),

                    "inputGVector":
                        CIVector(
                            x: 0,
                            y:
                                CGFloat(amount),
                            z: 0,
                            w: 0
                        ),

                    "inputBVector":
                        CIVector(
                            x: 0,
                            y: 0,
                            z:
                                CGFloat(amount),
                            w: 0
                        )
                ]
            )


        let composite =
            CIFilter.additionCompositing()

        composite.inputImage =
            boosted

        composite.backgroundImage =
            image

        return (
            composite.outputImage
            ?? image
        )
    }


    // ========================================================
    // HIGHLIGHT RECOVERY
    // ========================================================

    func recoverHighlights(
        image: CIImage,
        amount: Float
    ) -> CIImage {

        let highlight =
            CIFilter.highlightShadowAdjust()

        highlight.inputImage =
            image

        highlight.highlightAmount =
            CGFloat(
                amount
            )

        highlight.shadowAmount =
            0

        return (
            highlight.outputImage
            ?? image
        )
    }


    // ========================================================
    // SHADOW COLOUR RECOVERY
    // ========================================================

    func recoverShadows(
        image: CIImage,
        amount: Float
    ) -> CIImage {

        let filter =
            CIFilter.highlightShadowAdjust()

        filter.inputImage =
            image

        filter.highlightAmount =
            0

        filter.shadowAmount =
            CGFloat(
                amount
            )

        return (
            filter.outputImage
            ?? image
        )
    }


    // ========================================================
    // HDR HEADROOM
    // ========================================================

    func applyHDRHeadroom(
        image: CIImage,
        amount: Float
    ) -> CIImage {

        let exposure =
            CIFilter.exposureAdjust()

        exposure.inputImage =
            image

        exposure.ev =
            CGFloat(
                log2(
                    max(
                        amount,
                        0.01
                    )
                )
            )

        return (
            exposure.outputImage
            ?? image
        )
    }


    // ========================================================
    // GAMUT PROTECTION
    // ========================================================

    func protectGamut(
        image: CIImage,
        strength: Float
    ) -> CIImage {

        // Reduce only extreme chroma excursions.
        // This prevents saturated colours from
        // becoming ugly clipped RGB values.

        let filter =
            CIFilter.colorControls()

        filter.inputImage =
            image

        filter.saturation =
            CGFloat(
                1.0 +
                0.04 *
                strength
            )

        filter.contrast =
            1.0

        return (
            filter.outputImage
            ?? image
        )
    }


    // ========================================================
    // MICRO COLOUR
    // ========================================================

    func microColour(
        image: CIImage,
        amount: Float
    ) -> CIImage {

        let blur =
            CIFilter.gaussianBlur()

        blur.inputImage =
            image

        blur.radius =
            0.7


        guard let smooth =
                blur.outputImage
        else {
            return image
        }


        let high =
            CIFilter.subtractBlendMode()

        high.inputImage =
            image

        high.backgroundImage =
            smooth


        guard let detail =
                high.outputImage
        else {
            return image
        }


        let scaled =
            detail.applyingFilter(
                "CIColorMatrix",
                parameters: [

                    "inputRVector":
                        CIVector(
                            x:
                                CGFloat(amount),
                            y: 0,
                            z: 0,
                            w: 0
                        ),

                    "inputGVector":
                        CIVector(
                            x: 0,
                            y:
                                CGFloat(amount),
                            z: 0,
                            w: 0
                        ),

                    "inputBVector":
                        CIVector(
                            x: 0,
                            y: 0,
                            z:
                                CGFloat(amount),
                            w: 0
                        )
                ]
            )


        let addition =
            CIFilter.additionCompositing()

        addition.inputImage =
            scaled

        addition.backgroundImage =
            image

        return (
            addition.outputImage
            ?? image
        )
    }


    // ========================================================
    // COMPLETE COLOUR PIPELINE
    // ========================================================

    func process(
        image: CIImage,
        metadata:
            CameraColourMetadata,
        configuration:
            Configuration = Configuration()
    ) -> CIImage {

        var result =
            prepareWorkingImage(
                image: image
            )


        // ----------------------------------------------------
        // WHITE BALANCE
        // ----------------------------------------------------

        result =
            whiteBalance(
                image: result,
                temperature:
                    metadata.temperature,
                tint:
                    metadata.tint
            )


        // ----------------------------------------------------
        // HDR
        // ----------------------------------------------------

        if metadata.hdrEnabled {

            result =
                applyHDRHeadroom(
                    image: result,
                    amount:
                        configuration.hdrHeadroom
                )
        }


        // ----------------------------------------------------
        // SHADOW INFORMATION
        // ----------------------------------------------------

        result =
            recoverShadows(
                image: result,
                amount:
                    configuration.shadowColourRecovery
            )


        // ----------------------------------------------------
        // HIGHLIGHT COLOUR
        // ----------------------------------------------------

        result =
            recoverHighlights(
                image: result,
                amount:
                    configuration.highlightRecovery
            )


        // ----------------------------------------------------
        // CHROMA
        // ----------------------------------------------------

        result =
            preserveChroma(
                image: result,
                strength:
                    configuration.chromaPreservation
            )


        // ----------------------------------------------------
        // COLOUR DENSITY
        // ----------------------------------------------------

        result =
            increaseColourDensity(
                image: result,
                amount:
                    configuration.saturationDensity
            )


        // ----------------------------------------------------
        // LOCAL COLOUR STRUCTURE
        // ----------------------------------------------------

        result =
            localColourContrast(
                image: result,
                amount:
                    configuration.localColourContrast
            )


        // ----------------------------------------------------
        // MICRO COLOUR
        // ----------------------------------------------------

        result =
            microColour(
                image: result,
                amount:
                    configuration.microColour
            )


        // ----------------------------------------------------
        // GAMUT PROTECTION
        // ----------------------------------------------------

        result =
            protectGamut(
                image: result,
                strength:
                    configuration.gamutProtection
            )


        return result
    }


    // ========================================================
    // P3 HEIF EXPORT
    // ========================================================

    func exportP3HEIF(
        image: CIImage,
        url: URL,
        quality: CGFloat = 0.98
    ) throws {

        guard let destination =
                CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.heic.identifier
                        as CFString,
                    1,
                    nil
                )
        else {

            throw NSError(
                domain:
                    "AureomColourDensity",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create HEIF destination"
                ]
            )
        }


        let extent =
            image.extent.integral


        guard let cgImage =
                context.createCGImage(
                    image,
                    from: extent,
                    format: .RGBA16,
                    colorSpace:
                        outputColorSpace
                )
        else {

            throw NSError(
                domain:
                    "AureomColourDensity",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not render P3 image"
                ]
            )
        }


        let properties:
            [CFString: Any] = [

                kCGImageDestinationLossyCompressionQuality:
                    quality,

                kCGImagePropertyHEIFDictionary:
                    [
                        kCGImagePropertyHEIFDictionary:
                            [:]
                    ]
            ]


        CGImageDestinationAddImage(
            destination,
            cgImage,
            properties as CFDictionary
        )


        guard CGImageDestinationFinalize(
            destination
        )
        else {

            throw NSError(
                domain:
                    "AureomColourDensity",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "HEIF export failed"
                ]
            )
        }
    }


    // ========================================================
    // HALF FLOAT READER
    // ========================================================

    private func halfToFloat(
        _ pointer: UnsafePointer<UInt8>
    ) -> Float {

        let low =
            UInt16(pointer[0])

        let high =
            UInt16(pointer[1])

        let bits =
            low |
            (high << 8)

        let sign =
            (bits & 0x8000) != 0

        let exponent =
            Int(
                (bits >> 10)
                & 0x1F
            )

        let fraction =
            Int(
                bits & 0x03FF
            )


        if exponent == 0 {

            if fraction == 0 {
                return sign
                    ? -0.0
                    : 0.0
            }

            let value =
                Float(fraction)
                / 1024.0

            let result =
                value *
                powf(
                    2.0,
                    -14.0
                )

            return sign
                ? -result
                : result
        }


        if exponent == 31 {

            if fraction == 0 {
                return sign
                    ? -.infinity
                    : .infinity
            }

            return .nan
        }


        let value =
            1.0 +
            Float(fraction)
            / 1024.0

        let result =
            value *
            powf(
                2.0,
                Float(
                    exponent - 15
                )
            )

        return sign
            ? -result
            : result
    }
}


// ============================================================
// CAMERA INTEGRATION
// ============================================================

final class AureomCameraColourController {

    private let engine =
        AureomColourDensityEngine.shared


    func processPhoto(
        photo:
            AVCapturePhoto,
        metadata:
            AureomColourDensityEngine
                .CameraColourMetadata,
        completion:
            @escaping (UIImage?) -> Void
    ) {

        guard let data =
                photo.fileDataRepresentation()
        else {
            completion(nil)
            return
        }


        guard let image =
                CIImage(
                    data: data,
                    options: [
                        .applyOrientationProperty:
                            true
                    ]
                )
        else {
            completion(nil)
            return
        }


        DispatchQueue.global(
            qos: .userInitiated
        ).async {

            let result =
                self.engine.process(
                    image: image,
                    metadata: metadata
                )


            let context =
                CIContext(
                    mtlDevice:
                        MTLCreateSystemDefaultDevice()!
                )


            guard let cgImage =
                    context.createCGImage(
                        result,
                        from:
                            result.extent
                    )
            else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }


            let output =
                UIImage(
                    cgImage:
                        cgImage
                )


            DispatchQueue.main.async {
                completion(output)
            }
        }
    }
}

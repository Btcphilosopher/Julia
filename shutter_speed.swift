Pure Swift camera
import SwiftUI
import AVFoundation
import Photos

// MARK: - Camera Model

@MainActor
final class CameraModel: NSObject, ObservableObject {

    let session = AVCaptureSession()

    private let photoOutput =
        AVCapturePhotoOutput()

    private var videoInput:
        AVCaptureDeviceInput?

    @Published var isRunning = false
    @Published var cameraPosition: AVCaptureDevice.Position = .back

    @Published var zoom: CGFloat = 1.0

    @Published var flashMode: AVCaptureDevice.FlashMode = .off

    @Published var isCapturing = false

    func requestPermission() async -> Bool {

        await AVCaptureDevice.requestAccess(
            for: .video
        )
    }

    func configure() {

        session.beginConfiguration()

        session.sessionPreset =
            .photo

        configureCamera(
            position: cameraPosition
        )

        if session.canAddOutput(
            photoOutput
        ) {

            session.addOutput(
                photoOutput
            )

            photoOutput.isHighResolutionCaptureEnabled =
                true
        }

        session.commitConfiguration()
    }

    private func configureCamera(
        position: AVCaptureDevice.Position
    ) {

        guard let device =
            AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: position
            )
        else {
            return
        }

        do {

            let input =
                try AVCaptureDeviceInput(
                    device: device
                )

            if session.canAddInput(input) {

                session.addInput(input)

                videoInput = input
            }

            try device.lockForConfiguration()

            if device.isFocusModeSupported(
                .continuousAutoFocus
            ) {

                device.focusMode =
                    .continuousAutoFocus
            }

            if device.isExposureModeSupported(
                .continuousAutoExposure
            ) {

                device.exposureMode =
                    .continuousAutoExposure
            }

            device.unlockForConfiguration()

        } catch {

            print(
                "Camera error:",
                error
            )
        }
    }

    func start() {

        guard !session.isRunning else {
            return
        }

        DispatchQueue.global(
            qos: .userInitiated
        ).async {

            self.session.startRunning()

            Task { @MainActor in
                self.isRunning = true
            }
        }
    }

    func stop() {

        guard session.isRunning else {
            return
        }

        DispatchQueue.global(
            qos: .userInitiated
        ).async {

            self.session.stopRunning()

            Task { @MainActor in
                self.isRunning = false
            }
        }
    }

    // MARK: - Photo

    func capturePhoto() {

        guard !isCapturing else {
            return
        }

        isCapturing = true

        let settings =
            AVCapturePhotoSettings()

        settings.flashMode =
            flashMode

        settings.photoQualityPrioritization =
            .quality

        photoOutput.capturePhoto(
            with: settings,
            delegate: self
        )
    }

    // MARK: - Camera Switching

    func switchCamera() {

        guard let currentInput =
            videoInput
        else {
            return
        }

        session.beginConfiguration()

        session.removeInput(
            currentInput
        )

        cameraPosition =
            cameraPosition == .back
            ? .front
            : .back

        configureCamera(
            position: cameraPosition
        )

        session.commitConfiguration()
    }

    // MARK: - Zoom

    func setZoom(
        _ value: CGFloat
    ) {

        guard let device =
            videoInput?.device
        else {
            return
        }

        let maximum =
            min(
                device.activeFormat
                    .videoMaxZoomFactor,
                15
            )

        let clamped =
            max(
                1,
                min(
                    value,
                    maximum
                )
            )

        do {

            try device.lockForConfiguration()

            device.videoZoomFactor =
                clamped

            device.unlockForConfiguration()

            zoom = clamped

        } catch {

            print(error)
        }
    }

    // MARK: - Focus

    func focus(
        at point: CGPoint
    ) {

        guard let device =
            videoInput?.device
        else {
            return
        }

        do {

            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported {

                device.focusPointOfInterest =
                    point

                device.focusMode =
                    .autoFocus
            }

            if device.isExposurePointOfInterestSupported {

                device.exposurePointOfInterest =
                    point

                device.exposureMode =
                    .continuousAutoExposure
            }

            device.unlockForConfiguration()

        } catch {

            print(error)
        }
    }
}


// MARK: - Photo Delegate

extension CameraModel:
    AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo:
        AVCapturePhoto,
        error: Error?
    ) {

        guard error == nil else {
            return
        }

        guard let data =
            photo.fileDataRepresentation()
        else {
            return
        }

        let image =
            UIImage(
                data: data
            )

        guard let image else {
            return
        }

        UIImageWriteToSavedPhotosAlbum(
            image,
            nil,
            nil,
            nil
        )

        Task { @MainActor in
            self.isCapturing = false
        }
    }
}
Live camera preview
struct CameraPreview:
    UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(
        context: Context
    ) -> PreviewView {

        let view =
            PreviewView()

        view.videoPreviewLayer.session =
            session

        view.videoPreviewLayer.videoGravity =
            .resizeAspectFill

        return view
    }

    func updateUIView(
        _ view: PreviewView,
        context: Context
    ) {}
}


final class PreviewView:
    UIView {

    override class var layerClass:
        AnyClass {

        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer:
        AVCaptureVideoPreviewLayer {

        layer
            as! AVCaptureVideoPreviewLayer
    }
}
The actual Camera UI

This is where I'd make the biggest departure from a conventional implementation.

struct CameraView: View {

    @StateObject
    private var camera =
        CameraModel()

    @State
    private var appeared = false

    @State
    private var zoomGesture:
        CGFloat = 1

    var body: some View {

        ZStack {

            Color.black
                .ignoresSafeArea()

            CameraPreview(
                session: camera.session
            )
            .ignoresSafeArea()

            // MARK: Top controls

            VStack {

                HStack {

                    CameraControl(
                        icon:
                            "bolt.slash.fill"
                    )

                    Spacer()

                    CameraControl(
                        icon:
                            "timer"
                    )

                    CameraControl(
                        icon:
                            "gearshape"
                    )
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                Spacer()

                // MARK: Zoom

                ZoomSelector(
                    zoom:
                        Binding(
                            get: {
                                camera.zoom
                            },
                            set: {
                                camera.setZoom($0)
                            }
                        )
                )

                Spacer()

                // MARK: Bottom controls

                HStack {

                    GalleryButton()

                    Spacer()

                    ShutterButton {

                        camera.capturePhoto()
                    }

                    Spacer()

                    CameraControl(
                        icon:
                            "arrow.triangle.2.circlepath.camera"
                    ) {

                        withAnimation(
                            .spring(
                                response: 0.38,
                                dampingFraction: 0.82
                            )
                        ) {

                            camera.switchCamera()
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .scaleEffect(
            appeared
            ? 1
            : 0.985
        )
        .opacity(
            appeared
            ? 1
            : 0
        )
        .animation(
            .easeOut(duration: 0.35),
            value: appeared
        )
        .task {

            let granted =
                await camera
                    .requestPermission()

            guard granted else {
                return
            }

            camera.configure()
            camera.start()

            appeared = true
        }
        .onDisappear {

            camera.stop()
        }
    }
}
Shutter button
struct ShutterButton: View {

    let action: () -> Void

    @State
    private var pressed = false

    var body: some View {

        Button {

            action()

        } label: {

            ZStack {

                Circle()
                    .fill(.white)
                    .frame(
                        width: 78,
                        height: 78
                    )

                Circle()
                    .stroke(
                        .white.opacity(0.7),
                        lineWidth: 4
                    )
                    .frame(
                        width: 88,
                        height: 88
                    )
            }
            .scaleEffect(
                pressed
                ? 0.88
                : 1
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(
                minimumDistance: 0
            )
            .onChanged { _ in

                withAnimation(
                    .spring(
                        response: 0.15,
                        dampingFraction: 0.8
                    )
                ) {
                    pressed = true
                }
            }
            .onEnded { _ in

                withAnimation(
                    .spring(
                        response: 0.25,
                        dampingFraction: 0.8
                    )
                ) {
                    pressed = false
                }
            }
        )
    }
}
Fluid zoom

Rather than discrete buttons, I'd make zoom continuous.

struct ZoomSelector: View {

    @Binding
    var zoom: CGFloat

    @State
    private var baseZoom: CGFloat = 1

    var body: some View {

        HStack(spacing: 10) {

            ForEach(
                [0.5, 1.0, 2.0, 5.0],
                id: \.self
            ) { value in

                Button {

                    withAnimation(
                        .spring(
                            response: 0.3,
                            dampingFraction: 0.8
                        )
                    ) {

                        zoom = value
                    }

                } label: {

                    Text(
                        value == 0.5
                        ? ".5"
                        : "\(Int(value))x"
                    )
                    .font(
                        .system(
                            size: 13,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .frame(
                        width: 42,
                        height: 42
                    )
                    .background {

                        Circle()
                            .fill(
                                abs(zoom - value)
                                < 0.15
                                ? .white.opacity(0.2)
                                : .black.opacity(0.2)
                            )
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .gesture(

            MagnifyGesture()
                .onChanged { value in

                    let newZoom =
                        baseZoom
                        * value.magnification

                    zoom =
                        max(
                            0.5,
                            min(
                                newZoom,
                                15
                            )
                        )
                }
                .onEnded { _ in

                    baseZoom = zoom
                }
        )
    }
}
Apple-style controls
struct CameraControl: View {

    let icon: String
    var action: (() -> Void)? = nil

    var body: some View {

        Button {

            action?()

        } label: {

            Image(
                systemName: icon
            )
            .font(
                .system(
                    size: 17,
                    weight: .medium
                )
            )
            .frame(
                width: 44,
                height: 44
            )
            .background {

                Circle()
                    .fill(
                        .black.opacity(0.22)
                    )
                    .background(
                        .ultraThinMaterial,
                        in: Circle()
                    )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}



Fast-capture configuration
import AVFoundation

extension CameraModel {

    func configureForFastCapture() {

        guard let device = videoInput?.device else {
            return
        }

        session.beginConfiguration()

        do {

            try device.lockForConfiguration()

            // Continuous autofocus keeps the camera ready.
            if device.isFocusModeSupported(
                .continuousAutoFocus
            ) {
                device.focusMode =
                    .continuousAutoFocus
            }

            // Continuous exposure keeps exposure
            // prepared before the shutter is pressed.
            if device.isExposureModeSupported(
                .continuousAutoExposure
            ) {
                device.exposureMode =
                    .continuousAutoExposure
            }

            // Keep the lens/ISP ready rather than
            // forcing a focus operation at capture time.
            device.isSubjectAreaChangeMonitoringEnabled =
                true

            device.unlockForConfiguration()

            // Tell AVFoundation to prioritize
            // capture speed rather than maximum processing.
            photoOutput.photoQualityPrioritization =
                .speed

        } catch {

            print(
                "Fast capture configuration:",
                error
            )
        }

        session.commitConfiguration()
    }
}

Then your shutter becomes extremely small:

func captureFast() {

    guard !isCapturing else {
        return
    }

    isCapturing = true

    let settings =
        AVCapturePhotoSettings()

    settings.flashMode =
        .off

    settings.photoQualityPrioritization =
        .speed

    photoOutput.capturePhoto(
        with: settings,
        delegate: self
    )
}
If you specifically want manual shutter speed

You can control exposure duration through AVCaptureDevice.setExposureModeCustom.

func setShutterSpeed(
    seconds: Double
) {

    guard let device =
        videoInput?.device
    else {
        return
    }

    let duration =
        CMTimeMakeWithSeconds(
            seconds,
            preferredTimescale: 1_000_000
        )

    let clamped =
        CMTimeMaximum(
            duration,
            device.activeFormat
                .minExposureDuration
        )

    let finalDuration =
        CMTimeMinimum(
            clamped,
            device.activeFormat
                .maxExposureDuration
        )

    do {

        try device.lockForConfiguration()

        device.setExposureModeCustom(
            duration: finalDuration,
            iso: AVCaptureDevice.currentISO
        ) { _ in }

        device.unlockForConfiguration()

    } catch {

        print(
            "Exposure error:",
            error
        )
    }
}

For example:

setShutterSpeed(
    seconds: 1.0 / 1000.0
)

gives approximately 1/1000 second.

Useful presets:

enum ShutterPreset {

    case auto
    case motion
    case sport
    case night

    var seconds: Double? {

        switch self {

        case .auto:
            return nil

        case .motion:
            return 1.0 / 250.0

        case .sport:
            return 1.0 / 1000.0

        case .night:
            return 1.0 / 30.0
        }
    }
}








Julia adaptive shutter engine
module ShutterEngine

using Statistics

export ExposureState,
       shutter_speed,
       exposure_target,
       recommend_exposure


struct ExposureState

    brightness::Float64
    motion::Float64
    iso::Float64
    frame_rate::Float64

    # 0 = very dark
    # 1 = very bright

    lens::Symbol

end


function clamp01(x)

    clamp(x, 0.0, 1.0)

end


# Convert seconds to human-readable
# photographic shutter notation.

function shutter_label(seconds)

    if seconds >= 1

        return "$(round(seconds, digits=2))s"

    end

    denominator =
        round(Int, 1 / seconds)

    return "1/$(denominator)s"

end


function minimum_shutter(
    motion::Float64
)

    motion =
        clamp01(motion)

    if motion > 0.85

        return 1 / 2000

    elseif motion > 0.70

        return 1 / 1000

    elseif motion > 0.50

        return 1 / 500

    elseif motion > 0.30

        return 1 / 250

    elseif motion > 0.15

        return 1 / 120

    else

        return 1 / 60

    end

end


function brightness_shutter(
    brightness::Float64
)

    brightness =
        clamp01(brightness)

    # Bright scene → faster shutter
    # Dark scene → longer shutter

    if brightness > 0.90

        return 1 / 1000

    elseif brightness > 0.75

        return 1 / 500

    elseif brightness > 0.55

        return 1 / 250

    elseif brightness > 0.35

        return 1 / 120

    elseif brightness > 0.18

        return 1 / 60

    else

        return 1 / 30

    end

end


function shutter_speed(
    state::ExposureState
)

    motion_target =
        minimum_shutter(
            state.motion
        )

    brightness_target =
        brightness_shutter(
            state.brightness
        )

    # Select the faster exposure
    # when motion requires it.

    return min(
        motion_target,
        brightness_target
    )

end


function exposure_target(
    state::ExposureState
)

    shutter =
        shutter_speed(
            state
        )

    # Simplified exposure model.
    #
    # EV ∝ log2(N² / t)
    #
    # We don't change aperture here,
    # since iPhone apertures are generally
    # fixed per lens.

    aperture = 1.8

    ev =
        log2(
            aperture^2 / shutter
        )

    return (
        shutter = shutter,
        aperture = aperture,
        ev = ev
    )

end


function recommend_exposure(
    state::ExposureState
)

    target =
        exposure_target(
            state
        )

    return Dict(

        "shutter_seconds" =>
            target.shutter,

        "shutter" =>
            shutter_label(
                target.shutter
            ),

        "aperture" =>
            target.aperture,

        "ev" =>
            target.ev,

        "motion" =>
            state.motion,

        "brightness" =>
            state.brightness

    )

end

end
Example
using .ShutterEngine

scene =
    ExposureState(
        0.82,     # brightness
        0.72,     # motion
        100,      # ISO
        60,       # FPS
        :wide
    )

recommend_exposure(scene)

You'd get a recommendation along the lines of:

shutter_seconds = 0.001
shutter         = "1/1000s"
aperture        = 1.8
Better: make Julia optimize the entire exposure

Rather than hard-coding thresholds, I'd make Julia solve for the combination of:

shutter
ISO
motion blur
brightness
noise
dynamic range

with an objective function:

function exposure_cost(
    shutter,
    iso,
    brightness,
    motion
)

    motion_blur =
        motion * shutter

    noise =
        log(iso / 100 + 1)

    underexposure =
        max(
            0,
            0.25 -
            brightness *
            iso *
            shutter
        )

    return (
        4.0 * motion_blur^2 +
        1.5 * noise^2 +
        8.0 * underexposure^2
    )

end

Then search the available exposure space:

function optimize_exposure(
    brightness,
    motion
)

    shutters = [
        1/2000,
        1/1000,
        1/500,
        1/250,
        1/125,
        1/60,
        1/30
    ]

    isos = [
        50,
        64,
        100,
        200,
        400,
        800,
        1600
    ]

    best_cost = Inf
    best = nothing

    for shutter in shutters

        for iso in isos

            cost =
                exposure_cost(
                    shutter,
                    iso,
                    brightness,
                    motion
                )

            if cost < best_cost

                best_cost = cost

                best = (
                    shutter = shutter,
                    iso = iso,
                    cost = cost
                )

            end

        end

    end

    return best

end

Example:

optimize_exposure(
    0.72,
    0.65
)


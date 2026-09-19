Core Swift sound optimiser
import AVFoundation
import Accelerate
import Foundation

actor AureomSoundOptimiser {

    struct Parameters: Sendable {
        var preGain: Float = 0
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0
        var compression: Float = 0
        var stereoWidth: Float = 1.0
        var limiter: Float = -1.0
    }

    private(set) var parameters = Parameters()

    // Target perceptual balance.
    private let targetRMS: Float = 0.18

    // MARK: Analyse audio

    func analyse(_ samples: [Float]) -> AudioAnalysis {

        guard !samples.isEmpty else {
            return AudioAnalysis(
                rms: 0,
                peak: 0,
                crestFactor: 0,
                spectralCentroid: 0,
                bassEnergy: 0,
                midEnergy: 0,
                trebleEnergy: 0
            )
        }

        var rms: Float = 0
        var peak: Float = 0

        vDSP_rmsqv(
            samples,
            1,
            &rms,
            vDSP_Length(samples.count)
        )

        vDSP_maxmgv(
            samples,
            1,
            &peak,
            vDSP_Length(samples.count)
        )

        let crest =
            peak / max(rms, 0.000001)

        let spectrum = fft(samples)

        let bass = bandEnergy(
            spectrum,
            low: 20,
            high: 250
        )

        let mid = bandEnergy(
            spectrum,
            low: 250,
            high: 4000
        )

        let treble = bandEnergy(
            spectrum,
            low: 4000,
            high: 18000
        )

        return AudioAnalysis(
            rms: rms,
            peak: peak,
            crestFactor: crest,
            spectralCentroid: spectralCentroid(spectrum),
            bassEnergy: bass,
            midEnergy: mid,
            trebleEnergy: treble
        )
    }

    // MARK: Optimisation

    func optimise(
        analysis: AudioAnalysis
    ) -> Parameters {

        var result = parameters

        // --------------------------------------------
        // Loudness
        // --------------------------------------------

        let loudnessError =
            targetRMS - analysis.rms

        result.preGain +=
            loudnessError * 2.0

        result.preGain =
            min(max(result.preGain, -6), 6)

        // --------------------------------------------
        // Dynamic range
        // --------------------------------------------

        if analysis.crestFactor > 8 {

            result.compression =
                min(
                    result.compression + 0.03,
                    0.75
                )

        } else {

            result.compression =
                max(
                    result.compression - 0.01,
                    0
                )
        }

        // --------------------------------------------
        // Spectral balance
        // --------------------------------------------

        if analysis.bassEnergy < 0.15 {
            result.bass += 0.5
        }

        if analysis.bassEnergy > 0.65 {
            result.bass -= 0.5
        }

        if analysis.trebleEnergy < 0.12 {
            result.treble += 0.35
        }

        if analysis.trebleEnergy > 0.70 {
            result.treble -= 0.35
        }

        result.bass =
            min(max(result.bass, -6), 6)

        result.mid =
            min(max(result.mid, -6), 6)

        result.treble =
            min(max(result.treble, -6), 6)

        parameters = result

        return result
    }

    // MARK: FFT

    private func fft(
        _ input: [Float]
    ) -> [Float] {

        let count = input.count
        guard count >= 2 else { return [] }

        let log2n =
            vDSP_Length(log2(Double(count)))

        guard (1 << log2n) == count else {
            return []
        }

        var real = [Float](repeating: 0, count: count / 2)
        var imaginary = [Float](
            repeating: 0,
            count: count / 2
        )

        var split = DSPSplitComplex(
            realp: &real,
            imagp: &imaginary
        )

        let setup = vDSP_create_fftsetup(
            log2n,
            FFTRadix(kFFTRadix2)
        )

        defer {
            vDSP_destroy_fftsetup(setup)
        }

        input.withUnsafeBufferPointer { buffer in

            buffer.baseAddress!.withMemoryRebound(
                to: DSPComplex.self,
                capacity: count / 2
            ) { complex in

                vDSP_ctoz(
                    complex,
                    2,
                    &split,
                    1,
                    vDSP_Length(count / 2)
                )
            }
        }

        vDSP_fft_zrip(
            setup!,
            &split,
            1,
            log2n,
            FFTDirection(FFT_FORWARD)
        )

        var magnitudes =
            [Float](
                repeating: 0,
                count: count / 2
            )

        vDSP_zvmags(
            &split,
            1,
            &magnitudes,
            1,
            vDSP_Length(count / 2)
        )

        return magnitudes
    }

    private func bandEnergy(
        _ spectrum: [Float],
        low: Float,
        high: Float
    ) -> Float {

        guard !spectrum.isEmpty else {
            return 0
        }

        let sampleRate: Float = 48_000
        let fftSize = Float(spectrum.count * 2)

        let lowBin =
            Int(low / sampleRate * fftSize)

        let highBin =
            min(
                Int(high / sampleRate * fftSize),
                spectrum.count - 1
            )

        guard highBin > lowBin else {
            return 0
        }

        var sum: Float = 0

        for i in lowBin...highBin {
            sum += spectrum[i]
        }

        return sum / Float(highBin - lowBin + 1)
    }

    private func spectralCentroid(
        _ spectrum: [Float]
    ) -> Float {

        guard !spectrum.isEmpty else {
            return 0
        }

        var weighted: Float = 0
        var total: Float = 0

        for i in spectrum.indices {

            let frequency =
                Float(i) * 48_000 /
                Float(spectrum.count * 2)

            weighted += frequency * spectrum[i]
            total += spectrum[i]
        }

        return weighted / max(total, 0.000001)
    }
}

// MARK: - Analysis

struct AudioAnalysis: Sendable {

    let rms: Float
    let peak: Float
    let crestFactor: Float
    let spectralCentroid: Float

    let bassEnergy: Float
    let midEnergy: Float
    let trebleEnergy: Float
}

But I'd take it considerably further for an actual iOS Sound Controller.

2. Real-time AVAudioEngine

The architecture should look like:

              Audio source
                   │
                   ▼
          AVAudioEngine input
                   │
                   ▼
            ┌─────────────┐
            │ FFT / DSP   │
            └──────┬──────┘
                   │
       ┌───────────┼───────────┐
       ▼           ▼           ▼
     Bass         Mid        Treble
       │           │           │
       └───────────┼───────────┘
                   ▼
           Perceptual model
                   │
                   ▼
             DSP controller
                   │
       ┌───────────┼───────────┐
       ▼           ▼           ▼
      EQ       Compressor    Limiter
                   │
                   ▼
             Spatial audio
                   │
                   ▼
             AVAudioEngine
                   │
                   ▼
            iPhone output

The DSP should run on the real-time audio thread, while the expensive analysis runs separately.

For example:

final class AureomAudioController {

    let engine = AVAudioEngine()

    private let equalizer =
        AVAudioUnitEQ(numberOfBands: 5)

    private let compressor =
        AVAudioUnitDynamicsProcessor()

    private let reverb =
        AVAudioUnitReverb()

    func configure() throws {

        let session =
            AVAudioSession.sharedInstance()

        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [
                .allowBluetooth,
                .allowBluetoothA2DP
            ]
        )

        try session.setActive(true)

        configureEQ()

        engine.attach(equalizer)
        engine.attach(compressor)
        engine.attach(reverb)

        let format =
            engine.mainMixerNode.outputFormat(
                forBus: 0
            )

        engine.connect(
            engine.inputNode,
            to: equalizer,
            format: format
        )

        engine.connect(
            equalizer,
            to: compressor,
            format: format
        )

        engine.connect(
            compressor,
            to: reverb,
            format: format
        )

        engine.connect(
            reverb,
            to: engine.mainMixerNode,
            format: format
        )

        engine.prepare()

        try engine.start()
    }

    private func configureEQ() {

        let frequencies: [Float] = [
            60,
            250,
            1000,
            4000,
            12000
        ]

        for (index, frequency)
            in frequencies.enumerated() {

            let band =
                equalizer.bands[index]

            band.frequency = frequency
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
    }
}
3. Adaptive EQ

The interesting algorithm is to avoid blindly boosting frequencies.

Instead:

Measure spectrum
       ↓
Estimate perceived imbalance
       ↓
Determine correction
       ↓
Apply correction slowly
       ↓
Measure again
       ↓
Repeat

You want a damped controller:

func smooth(
    old: Float,
    target: Float,
    alpha: Float = 0.08
) -> Float {

    old + (target - old) * alpha
}

This is important because without smoothing, the EQ can "hunt":

+3 dB
-2 dB
+4 dB
-3 dB
...

which sounds terrible.

Instead:

current EQ
     │
     ├── target EQ
     │
     ▼
low-pass controller
     │
     ▼
smooth perceptual transition
4. Add a proper loudness controller

I'd also use an LUFS-style loudness estimate rather than relying only on RMS.

Conceptually:

$$ L = -0.691 + 10\log_{10} \left( \frac{1}{N} \sum x_i^2 \right) $$

Then maintain a target loudness:

struct LoudnessController {

    var targetLUFS: Float = -14

    mutating func gain(
        measuredLUFS: Float
    ) -> Float {

        let error =
            targetLUFS - measuredLUFS

        return min(
            max(error * 0.35, -6),
            6
        )
    }
}

That gives you a much more sophisticated system than:

volume += 0.1
5. The really interesting version: perceptual optimisation

For Aureom, I'd eventually make the controller optimise:

$$ J = w_L L_{\text{loudness}} + w_S S_{\text{spectral}} + w_D D_{\text{dynamic}} + w_T T_{\text{transient}} + w_C C_{\text{clipping}} $$

where the controller attempts to minimise perceptual error rather than simply maximise volume.

That lets it distinguish:

quiet

from

compressed

from

bass-heavy

from

harsh

from

muddy

from

clipped

from

wide/immersive.

Swift + Julia architecture

Given the kind of system you've been building, I'd use:

Swift

AVAudioEngine
AVAudioSession
AVAudioUnitEQ
dynamics processor
FFT
real-time DSP
device/output management
UI

Accelerate

FFT
vector operations
convolution
RMS/loudness calculations

Julia

optimisation
perceptual model training
parameter fitting
acoustic simulations
DSP experimentation
offline dataset analysis

Core ML

optional learned classifier:
speech
music
podcast
film
EDM
classical
noisy environment
voice call

The result becomes an Aureom Adaptive Sound Controller that isn't merely an equaliser — it continuously estimates what the audio is doing and adjusts the reproduction chain toward a target perceptual response.

One important iOS constraint: a normal third-party app cannot globally intercept and rewrite all system audio. The controller can process audio that your app owns/routes through its audio engine, while Apple's system audio stack and hardware ultimately control system-wide output.

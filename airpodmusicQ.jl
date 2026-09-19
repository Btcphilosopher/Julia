Here's a native Swift starting point.

import AVFoundation
import Accelerate

final class AureomMusicQualityEngine {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var eq: AVAudioUnitEQ!
    private var limiter: AVAudioUnitDynamicsProcessor!

    init() {
        configureAudioSession()
        configureEngine()
    }

    private func configureAudioSession() {

        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(
                .playback,
                mode: .music,
                options: [
                    .allowAirPlay
                ]
            )

            try session.setActive(true)

        } catch {
            print("Audio session error:", error)
        }
    }

    private func configureEngine() {

        eq = AVAudioUnitEQ(numberOfBands: 5)

        configureEQ()

        limiter = AVAudioUnitDynamicsProcessor()

        configureLimiter()

        engine.attach(player)
        engine.attach(eq)
        engine.attach(limiter)

        engine.connect(
            player,
            to: eq,
            format: nil
        )

        engine.connect(
            eq,
            to: limiter,
            format: nil
        )

        engine.connect(
            limiter,
            to: engine.mainMixerNode,
            format: nil
        )

        engine.prepare()
    }
}
High-quality EQ

Rather than simply turning everything up, give the engine controlled bands:

private extension AureomMusicQualityEngine {

    func configureEQ() {

        let bands = eq.bands

        // Sub bass
        bands[0].filterType = .lowShelf
        bands[0].frequency = 55
        bands[0].bandwidth = 0.7
        bands[0].gain = 1.5
        bands[0].bypass = false

        // Low mids
        bands[1].filterType = .parametric
        bands[1].frequency = 180
        bands[1].bandwidth = 0.8
        bands[1].gain = 0.5
        bands[1].bypass = false

        // Presence
        bands[2].filterType = .parametric
        bands[2].frequency = 2500
        bands[2].bandwidth = 0.9
        bands[2].gain = 1.0
        bands[2].bypass = false

        // Detail
        bands[3].filterType = .parametric
        bands[3].frequency = 7000
        bands[3].bandwidth = 0.7
        bands[3].gain = 1.0
        bands[3].bypass = false

        // Air
        bands[4].filterType = .highShelf
        bands[4].frequency = 12000
        bands[4].bandwidth = 0.7
        bands[4].gain = 1.5
        bands[4].bypass = false
    }
}

The idea is small corrections rather than aggressive EQ, because excessive boosting can make AirPods sound louder but actually reduce usable quality.

Add a transparent limiter
private extension AureomMusicQualityEngine {

    func configureLimiter() {

        limiter.threshold = -2.0
        limiter.headRoom = 2.0
        limiter.expansionRatio = 1.0
        limiter.expansionThreshold = -80.0
        limiter.attackTime = 0.001
        limiter.releaseTime = 0.08
    }
}

Then expose playback:

extension AureomMusicQualityEngine {

    func start() {

        guard !engine.isRunning else {
            return
        }

        do {
            try engine.start()
            player.play()
        } catch {
            print("Engine start failed:", error)
        }
    }

    func stop() {

        player.stop()
        engine.stop()
    }
}
The more interesting version: adaptive music processing

You can analyse the incoming PCM and dynamically adjust processing.

For example:

struct AudioAnalysis {

    var rms: Float
    var peak: Float
    var crestFactor: Float
    var bassEnergy: Float
    var midEnergy: Float
    var trebleEnergy: Float
}

Using Accelerate:

func analyse(
    buffer: AVAudioPCMBuffer
) -> AudioAnalysis {

    guard
        let channel = buffer.floatChannelData?[0]
    else {
        return AudioAnalysis(
            rms: 0,
            peak: 0,
            crestFactor: 0,
            bassEnergy: 0,
            midEnergy: 0,
            trebleEnergy: 0
        )
    }

    let count = Int(buffer.frameLength)

    var rms: Float = 0

    vDSP_rmsqv(
        channel,
        1,
        &rms,
        vDSP_Length(count)
    )

    var peak: Float = 0

    vDSP_maxmgv(
        channel,
        1,
        &peak,
        vDSP_Length(count)
    )

    let crest =
        peak / max(rms, 0.000001)

    return AudioAnalysis(
        rms: rms,
        peak: peak,
        crestFactor: crest,
        bassEnergy: 0,
        midEnergy: 0,
        trebleEnergy: 0
    )
}

You can then make the processing programme-dependent.

For example:

Classical
    ↓
very low processing
large dynamic range
minimal EQ

Rock
    ↓
bass control
midrange clarity
transient preservation

EDM
    ↓
sub-bass protection
kick/transient preservation
controlled limiter

Vocals
    ↓
presence optimisation
low-mid cleanup
air enhancement
And this is where your Julia idea becomes interesting

You could have Swift process the audio in real time, while Julia develops the adaptive model:

                MUSIC
                  ↓
            Swift / AVAudio
                  ↓
             PCM Float32
                  ↓
        ┌───────────────────┐
        │   Audio analysis  │
        └─────────┬─────────┘
                  ↓
                Julia
                  ↓
       ┌──────────────────────┐
       │ spectral intelligence│
       │ dynamic-range model  │
       │ genre characteristics│
       │ room/headphone model │
       └──────────┬───────────┘
                  ↓
            DSP parameters
                  ↓
              Swift DSP
                  ↓
               AirPods

That could become an Aureom Adaptive Audio Engine where the processing is continuously adjusted according to the actual music rather than applying a fixed EQ preset.

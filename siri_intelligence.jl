module AccentML

using FFTW
using LinearAlgebra
using Statistics
using Random

############################################################
# CONFIG
############################################################

Base.@kwdef struct Config
    sample_rate::Int = 16000
    frame_size::Int = 400       # 25 ms
    hop_size::Int = 160         # 10 ms
    n_filters::Int = 26
    n_mfcc::Int = 13
    hidden_size::Int = 64
end


############################################################
# AUDIO PREPROCESSING
############################################################

function preprocess(x::Vector{Float32})

    # Remove DC offset
    x = x .- mean(x)

    # Peak normalisation
    peak = maximum(abs.(x))

    if peak > 0
        x ./= peak
    end

    return x
end


############################################################
# FRAMING
############################################################

function frames(
    x,
    cfg::Config
)

    n =
        length(x)

    result =
        Vector{Vector{Float32}}()

    pos = 1

    while pos + cfg.frame_size - 1 <= n

        push!(
            result,
            x[
                pos:
                pos + cfg.frame_size - 1
            ]
        )

        pos += cfg.hop_size

    end

    return result
end


############################################################
# HANN WINDOW
############################################################

function hann(n)

    return Float32[
        0.5 -
        0.5 *
        cos(
            2π * i / (n - 1)
        )
        for i in 0:n-1
    ]

end


############################################################
# POWER SPECTRUM
############################################################

function power_spectrum(
    frame
)

    windowed =
        frame .* hann(length(frame))

    spectrum =
        fft(windowed)

    n =
        div(length(frame), 2) + 1

    return abs2.(
        spectrum[1:n]
    )

end


############################################################
# MEL SCALE
############################################################

function hz_to_mel(f)

    return 2595 *
           log10(
               1 + f / 700
           )

end


function mel_to_hz(m)

    return 700 *
           (
               10^(m / 2595) - 1
           )

end


############################################################
# MEL FILTER BANK
############################################################

function mel_filterbank(
    cfg::Config
)

    low =
        hz_to_mel(80)

    high =
        hz_to_mel(
            cfg.sample_rate / 2
        )

    points =
        range(
            low,
            high;
            length =
                cfg.n_filters + 2
        )

    hz =
        mel_to_hz.(points)

    bins =
        floor.(
            (cfg.frame_size + 1) .* hz ./
            cfg.sample_rate
        )

    filters =
        zeros(
            Float32,
            cfg.n_filters,
            div(cfg.frame_size, 2) + 1
        )

    for m in 1:cfg.n_filters

        left =
            Int(bins[m]) + 1

        centre =
            Int(bins[m+1]) + 1

        right =
            Int(bins[m+2]) + 1

        for k in left:centre-1

            if centre != left

                filters[m,k] =
                    (k-left) /
                    (centre-left)

            end

        end

        for k in centre:right-1

            if right != centre

                filters[m,k] =
                    (right-k) /
                    (right-centre)

            end

        end

    end

    return filters

end


############################################################
# MFCC
############################################################

function mfcc(
    frame,
    cfg::Config,
    bank
)

    spectrum =
        power_spectrum(frame)

    energies =
        bank *
        spectrum

    energies =
        log.(
            energies .+
            1f-8
        )

    ########################################################
    # DCT
    ########################################################

    result =
        zeros(
            Float32,
            cfg.n_mfcc
        )

    for k in 1:cfg.n_mfcc

        result[k] =
            sum(
                energies[n] *
                cos(
                    π *
                    (n - 0.5) *
                    (k - 1) /
                    cfg.n_filters
                )
                for n in 1:cfg.n_filters
            )

    end

    return result

end


############################################################
# SPEECH FEATURE VECTOR
############################################################

function extract_features(
    audio::Vector{Float32},
    cfg::Config = Config()
)

    audio =
        preprocess(audio)

    fs =
        frames(
            audio,
            cfg
        )

    bank =
        mel_filterbank(cfg)

    feature_frames =
        [
            mfcc(
                frame,
                cfg,
                bank
            )
            for frame in fs
        ]

    ########################################################
    # Mean + variance gives a fixed-size representation
    # regardless of recording duration.
    ########################################################

    matrix =
        hcat(feature_frames...)

    μ =
        vec(
            mean(
                matrix,
                dims=2
            )
        )

    σ =
        vec(
            std(
                matrix,
                dims=2
            )
        )

    return vcat(
        μ,
        σ
    )

end


############################################################
# SMALL NEURAL NETWORK
############################################################

mutable struct AccentNetwork

    W1::Matrix{Float32}
    b1::Vector{Float32}

    W2::Matrix{Float32}
    b2::Vector{Float32}

end


function AccentNetwork(
    input_size,
    hidden_size,
    output_size
)

    return AccentNetwork(

        randn(
            Float32,
            hidden_size,
            input_size
        ) .* 0.05f0,

        zeros(
            Float32,
            hidden_size
        ),

        randn(
            Float32,
            output_size,
            hidden_size
        ) .* 0.05f0,

        zeros(
            Float32,
            output_size
        )

    )

end


############################################################
# RELU
############################################################

relu(x) =
    max.(x, 0f0)


############################################################
# SOFTMAX
############################################################

function softmax(x)

    y =
        x .-
        maximum(x)

    e =
        exp.(y)

    return e ./ sum(e)

end


############################################################
# FORWARD PASS
############################################################

function predict(
    model::AccentNetwork,
    x
)

    hidden =
        relu(
            model.W1 *
            x +
            model.b1
        )

    output =
        model.W2 *
        hidden +
        model.b2

    return softmax(output)

end


############################################################
# ACCENT PROFILE
############################################################

struct AccentProfile

    label::String

    confidence::Float64

    probabilities::Dict{
        String,
        Float64
    }

end


############################################################
# CLASSIFY
############################################################

function classify(
    model,
    audio,
    labels,
    cfg = Config()
)

    features =
        extract_features(
            audio,
            cfg
        )

    probabilities =
        predict(
            model,
            features
        )

    index =
        argmax(
            probabilities
        )

    probability_map =
        Dict(
            labels[i] =>
                Float64(
                    probabilities[i]
                )
            for i in eachindex(labels)
        )

    return AccentProfile(

        labels[index],

        Float64(
            probabilities[index]
        ),

        probability_map

    )

end

end











"""
AUREOM ACCENT INTELLIGENCE
==========================

Pure Python / NumPy implementation.

Pipeline:

    microphone/audio
          |
          v
    preprocessing
          |
          v
    framing + windowing
          |
          v
    FFT / power spectrum
          |
          v
    Mel filterbank
          |
          v
        MFCC
          |
          v
    acoustic embedding
          |
          v
    neural accent classifier
          |
          v
    accent probabilities
          |
          v
    ASR adaptation layer

The model is deliberately small so it can run locally.
"""

import math
import numpy as np
from dataclasses import dataclass
from typing import Dict, List, Optional


# ============================================================
# CONFIGURATION
# ============================================================

@dataclass
class AudioConfig:

    sample_rate: int = 16000

    frame_ms: float = 25.0
    hop_ms: float = 10.0

    n_mels: int = 26
    n_mfcc: int = 13

    low_frequency: float = 80.0
    high_frequency: float = 7600.0

    hidden_size: int = 64

    @property
    def frame_size(self):
        return int(
            self.sample_rate *
            self.frame_ms /
            1000.0
        )

    @property
    def hop_size(self):
        return int(
            self.sample_rate *
            self.hop_ms /
            1000.0
        )


# ============================================================
# AUDIO PREPROCESSING
# ============================================================

def preprocess_audio(
    audio: np.ndarray
) -> np.ndarray:

    audio = np.asarray(
        audio,
        dtype=np.float32
    )

    if audio.ndim > 1:

        # Convert stereo -> mono
        audio = np.mean(
            audio,
            axis=1
        )

    # Remove DC offset
    audio -= np.mean(audio)

    # Peak normalisation
    peak = np.max(
        np.abs(audio)
    )

    if peak > 1e-8:

        audio /= peak

    return audio


# ============================================================
# FRAMING
# ============================================================

def frame_audio(
    audio: np.ndarray,
    config: AudioConfig
):

    frame_size = config.frame_size
    hop_size = config.hop_size

    if len(audio) < frame_size:

        audio = np.pad(
            audio,
            (
                0,
                frame_size - len(audio)
            )
        )

    frames = []

    for start in range(
        0,
        len(audio) - frame_size + 1,
        hop_size
    ):

        frames.append(
            audio[
                start:start + frame_size
            ]
        )

    return np.asarray(
        frames,
        dtype=np.float32
    )


# ============================================================
# HANN WINDOW
# ============================================================

def hann_window(
    n: int
):

    return (
        0.5 -
        0.5 *
        np.cos(
            2.0 *
            np.pi *
            np.arange(n) /
            (n - 1)
        )
    ).astype(
        np.float32
    )


# ============================================================
# FREQUENCY / MEL CONVERSION
# ============================================================

def hz_to_mel(
    frequency
):

    return (
        2595.0 *
        np.log10(
            1.0 +
            frequency / 700.0
        )
    )


def mel_to_hz(
    mel
):

    return (
        700.0 *
        (
            10.0 **
            (mel / 2595.0)
            - 1.0
        )
    )


# ============================================================
# MEL FILTERBANK
# ============================================================

def create_mel_filterbank(
    config: AudioConfig
):

    n_fft_bins = (
        config.frame_size // 2
        + 1
    )

    low_mel = hz_to_mel(
        config.low_frequency
    )

    high_mel = hz_to_mel(
        config.high_frequency
    )

    mel_points = np.linspace(
        low_mel,
        high_mel,
        config.n_mels + 2
    )

    hz_points = mel_to_hz(
        mel_points
    )

    bins = np.floor(
        (
            config.frame_size + 1
        )
        *
        hz_points
        /
        config.sample_rate
    ).astype(int)

    filters = np.zeros(
        (
            config.n_mels,
            n_fft_bins
        ),
        dtype=np.float32
    )

    for m in range(
        1,
        config.n_mels + 1
    ):

        left = bins[m - 1]
        centre = bins[m]
        right = bins[m + 1]

        if centre > left:

            for k in range(
                left,
                centre
            ):

                if k < n_fft_bins:

                    filters[
                        m - 1,
                        k
                    ] = (
                        k - left
                    ) / (
                        centre - left
                    )

        if right > centre:

            for k in range(
                centre,
                right
            ):

                if k < n_fft_bins:

                    filters[
                        m - 1,
                        k
                    ] = (
                        right - k
                    ) / (
                        right - centre
                    )

    return filters


# ============================================================
# POWER SPECTRUM
# ============================================================

def power_spectrum(
    frame: np.ndarray
):

    window = hann_window(
        len(frame)
    )

    windowed = (
        frame *
        window
    )

    spectrum = np.fft.rfft(
        windowed
    )

    power = (
        np.abs(spectrum) ** 2
    )

    return power.astype(
        np.float32
    )


# ============================================================
# MFCC
# ============================================================

def compute_mfcc(
    frame: np.ndarray,
    config: AudioConfig,
    mel_bank: np.ndarray
):

    power = power_spectrum(
        frame
    )

    mel_energy = (
        mel_bank @ power
    )

    mel_energy = np.maximum(
        mel_energy,
        1e-10
    )

    log_energy = np.log(
        mel_energy
    )

    # DCT-II
    n = config.n_mels

    k = np.arange(
        config.n_mfcc
    )

    i = np.arange(n)

    basis = np.cos(
        np.pi *
        np.outer(
            k,
            i + 0.5
        ) /
        n
    )

    coefficients = (
        basis @ log_energy
    )

    return coefficients.astype(
        np.float32
    )


# ============================================================
# DELTA FEATURES
# ============================================================

def delta_features(
    features: np.ndarray
):

    delta = np.zeros_like(
        features
    )

    if len(features) < 2:

        return delta

    delta[1:-1] = (
        features[2:] -
        features[:-2]
    ) / 2.0

    delta[0] = (
        features[1] -
        features[0]
    )

    delta[-1] = (
        features[-1] -
        features[-2]
    )

    return delta


# ============================================================
# FEATURE EXTRACTION
# ============================================================

class SpeechFeatureExtractor:

    def __init__(
        self,
        config=None
    ):

        self.config = (
            config
            if config is not None
            else AudioConfig()
        )

        self.mel_bank = (
            create_mel_filterbank(
                self.config
            )
        )

    def extract(
        self,
        audio
    ):

        audio = preprocess_audio(
            audio
        )

        frames = frame_audio(
            audio,
            self.config
        )

        mfccs = np.asarray(
            [
                compute_mfcc(
                    frame,
                    self.config,
                    self.mel_bank
                )
                for frame in frames
            ]
        )

        deltas = delta_features(
            mfccs
        )

        # Mean + standard deviation
        mean = np.mean(
            mfccs,
            axis=0
        )

        std = np.std(
            mfccs,
            axis=0
        )

        delta_mean = np.mean(
            deltas,
            axis=0
        )

        delta_std = np.std(
            deltas,
            axis=0
        )

        feature_vector = np.concatenate(
            [
                mean,
                std,
                delta_mean,
                delta_std
            ]
        )

        return feature_vector.astype(
            np.float32
        )


# ============================================================
# SMALL NEURAL NETWORK
# ============================================================

class AccentNetwork:

    def __init__(
        self,
        input_size: int,
        hidden_size: int,
        output_size: int
    ):

        scale1 = math.sqrt(
            2.0 /
            input_size
        )

        scale2 = math.sqrt(
            2.0 /
            hidden_size
        )

        self.W1 = (
            np.random.randn(
                hidden_size,
                input_size
            ) *
            scale1
        ).astype(
            np.float32
        )

        self.b1 = np.zeros(
            hidden_size,
            dtype=np.float32
        )

        self.W2 = (
            np.random.randn(
                output_size,
                hidden_size
            ) *
            scale2
        ).astype(
            np.float32
        )

        self.b2 = np.zeros(
            output_size,
            dtype=np.float32
        )

    @staticmethod
    def relu(x):

        return np.maximum(
            x,
            0.0
        )

    @staticmethod
    def softmax(x):

        x = (
            x -
            np.max(x)
        )

        e = np.exp(x)

        return e / np.sum(e)

    def forward(
        self,
        x
    ):

        hidden = self.relu(
            self.W1 @ x +
            self.b1
        )

        logits = (
            self.W2 @ hidden +
            self.b2
        )

        probabilities = (
            self.softmax(
                logits
            )
        )

        return probabilities


# ============================================================
# ACCENT RESULT
# ============================================================

@dataclass
class AccentResult:

    label: str

    confidence: float

    probabilities: Dict[
        str,
        float
    ]

    embedding: np.ndarray


# ============================================================
# ACCENT ENGINE
# ============================================================

class AccentEngine:

    def __init__(
        self,
        labels: List[str],
        config=None
    ):

        self.config = (
            config
            if config is not None
            else AudioConfig()
        )

        self.labels = labels

        self.extractor = (
            SpeechFeatureExtractor(
                self.config
            )
        )

        feature_size = (
            self.config.n_mfcc *
            4
        )

        self.model = AccentNetwork(
            feature_size,
            self.config.hidden_size,
            len(labels)
        )

    def analyse(
        self,
        audio
    ):

        features = (
            self.extractor.extract(
                audio
            )
        )

        probabilities = (
            self.model.forward(
                features
            )
        )

        index = int(
            np.argmax(
                probabilities
            )
        )

        probability_map = {
            self.labels[i]:
                float(
                    probabilities[i]
                )
            for i in range(
                len(self.labels)
            )
        }

        return AccentResult(

            label=self.labels[index],

            confidence=float(
                probabilities[index]
            ),

            probabilities=probability_map,

            embedding=features

        )


# ============================================================
# ONLINE SPEAKER ADAPTATION
# ============================================================

class SpeakerAdaptation:

    """
    Stores acoustic examples associated with
    the user's own speech corrections.

    This is deliberately separate from the
    accent classifier.
    """

    def __init__(
        self,
        learning_rate=0.05
    ):

        self.learning_rate = (
            learning_rate
        )

        self.centroid = None

        self.samples = 0

    def update(
        self,
        embedding
    ):

        embedding = np.asarray(
            embedding,
            dtype=np.float32
        )

        if self.centroid is None:

            self.centroid = (
                embedding.copy()
            )

            self.samples = 1

            return

        self.centroid = (
            (
                1.0 -
                self.learning_rate
            )
            *
            self.centroid
            +
            self.learning_rate
            *
            embedding
        )

        self.samples += 1

    def similarity(
        self,
        embedding
    ):

        if self.centroid is None:

            return 0.0

        a = (
            embedding /
            (
                np.linalg.norm(
                    embedding
                ) + 1e-8
            )
        )

        b = (
            self.centroid /
            (
                np.linalg.norm(
                    self.centroid
                ) + 1e-8
            )
        )

        return float(
            np.dot(
                a,
                b
            )
        )


# ============================================================
# ASR ADAPTATION
# ============================================================

class SpeechAdaptationLayer:

    """
    Converts acoustic analysis into hints
    for a downstream speech recogniser.
    """

    def __init__(
        self,
        labels
    ):

        self.engine = (
            AccentEngine(
                labels
            )
        )

        self.speaker = (
            SpeakerAdaptation()
        )

    def process(
        self,
        audio
    ):

        result = (
            self.engine.analyse(
                audio
            )
        )

        speaker_similarity = (
            self.speaker.similarity(
                result.embedding
            )
        )

        return {
            "accent": result.label,

            "accent_confidence":
                result.confidence,

            "accent_probabilities":
                result.probabilities,

            "speaker_similarity":
                speaker_similarity,

            "embedding":
                result.embedding
        }

    def learn_from_user(
        self,
        audio
    ):

        embedding = (
            self.engine
            .extractor
            .extract(audio)
        )

        self.speaker.update(
            embedding
        )


# ============================================================
# EXAMPLE
# ============================================================

if __name__ == "__main__":

    labels = [

        "British English",

        "American English",

        "Irish English",

        "Scottish English",

        "Australian English",

        "Indian English",

        "Canadian English",

        "New Zealand English"

    ]

    assistant = (
        SpeechAdaptationLayer(
            labels
        )
    )

    # Example synthetic audio.
    # Replace this with microphone/ASR input.

    sample_rate = 16000

    duration = 2.0

    t = np.linspace(
        0,
        duration,
        int(
            sample_rate *
            duration
        ),
        endpoint=False
    )

    audio = (
        0.2 *
        np.sin(
            2 *
            np.pi *
            180 *
            t
        )
    ).astype(
        np.float32
    )

    result = assistant.process(
        audio
    )

    print(
        "Accent:",
        result["accent"]
    )

    print(
        "Confidence:",
        round(
            result["accent_confidence"],
            3
        )
    )

    print(
        "Probabilities:"
    )

    for (
        label,
        probability
    ) in result[
        "accent_probabilities"
    ].items():

        print(
            f"  {label:25s}"
            f"{probability:.3f}"
        )
        
        
        
        
        
        
        
        
        
        //
//  AccentIntelligence.swift
//
//  Siri-style accent/acoustic intelligence layer
//  Native iOS / Swift
//

import Foundation
import AVFoundation
import Accelerate
import CoreML


// ============================================================
// MARK: - Configuration
// ============================================================

struct AudioConfig {

    let sampleRate: Double = 16_000

    let frameMilliseconds: Double = 25
    let hopMilliseconds: Double = 10

    let melFilters: Int = 26
    let mfccCount: Int = 13

    let lowFrequency: Double = 80
    let highFrequency: Double = 7600

    var frameSize: Int {
        Int(
            sampleRate *
            frameMilliseconds /
            1000
        )
    }

    var hopSize: Int {
        Int(
            sampleRate *
            hopMilliseconds /
            1000
        )
    }
}


// ============================================================
// MARK: - Accent Result
// ============================================================

struct AccentResult {

    let label: String

    let confidence: Float

    let probabilities: [
        String: Float
    ]

    let embedding: [Float]
}


// ============================================================
// MARK: - Audio Preprocessor
// ============================================================

final class AudioPreprocessor {

    func mono(
        _ buffer: AVAudioPCMBuffer
    ) -> [Float] {

        guard let channelData =
                buffer.floatChannelData
        else {
            return []
        }

        let channels =
            Int(buffer.format.channelCount)

        let frames =
            Int(buffer.frameLength)

        var output =
            [Float](
                repeating: 0,
                count: frames
            )

        for channel in 0..<channels {

            let data =
                channelData[channel]

            for i in 0..<frames {

                output[i] +=
                    data[i] /
                    Float(channels)
            }
        }

        return output
    }


    func normalise(
        _ audio: [Float]
    ) -> [Float] {

        guard !audio.isEmpty else {
            return []
        }

        var mean: Float = 0

        vDSP_meanv(
            audio,
            1,
            &mean,
            vDSP_Length(audio.count)
        )

        var result =
            audio.map {
                $0 - mean
            }

        var maximum: Float = 0

        vDSP_maxmgv(
            result,
            1,
            &maximum,
            vDSP_Length(result.count)
        )

        if maximum > 0.000001 {

            var scale =
                1.0 / maximum

            vDSP_vsmul(
                result,
                1,
                &scale,
                &result,
                1,
                vDSP_Length(result.count)
            )
        }

        return result
    }
}


// ============================================================
// MARK: - FFT Engine
// ============================================================

final class FFTEngine {

    private let log2Size: vDSP_Length

    private let fft:
        vDSP.FFT<DSPSplitComplex>

    init?(size: Int) {

        guard
            size > 0,
            size & (size - 1) == 0
        else {
            return nil
        }

        log2Size =
            vDSP_Length(
                log2(Double(size))
            )

        guard let fft =
                vDSP.FFT<DSPSplitComplex>(
                    log2n: log2Size
                )
        else {
            return nil
        }

        self.fft = fft
    }


    func powerSpectrum(
        _ samples: [Float]
    ) -> [Float] {

        let n =
            samples.count

        var real =
            [Float](
                repeating: 0,
                count: n / 2
            )

        var imaginary =
            [Float](
                repeating: 0,
                count: n / 2
            )

        var split =
            DSPSplitComplex(
                realp: &real,
                imagp: &imaginary
            )

        samples.withUnsafeBufferPointer {
            input in

            input.baseAddress!.withMemoryRebound(
                to: DSPComplex.self,
                capacity: n
            ) { complexInput in

                fft.forward(
                    complexInput,
                    result: &split
                )
            }
        }

        var power =
            [Float](
                repeating: 0,
                count: n / 2
            )

        vDSP_zvmags(
            &split,
            1,
            &power,
            1,
            vDSP_Length(n / 2)
        )

        return power
    }
}


// ============================================================
// MARK: - Mel Scale
// ============================================================

func hzToMel(
    _ frequency: Double
) -> Double {

    return 2595.0 *
        log10(
            1.0 +
            frequency / 700.0
        )
}


func melToHz(
    _ mel: Double
) -> Double {

    return 700.0 *
        (
            pow(
                10.0,
                mel / 2595.0
            ) - 1.0
        )
}


// ============================================================
// MARK: - Mel Filterbank
// ============================================================

final class MelFilterBank {

    private let filters: [[Float]]

    init(
        config: AudioConfig
    ) {

        let nBins =
            config.frameSize / 2

        let lowMel =
            hzToMel(
                config.lowFrequency
            )

        let highMel =
            hzToMel(
                config.highFrequency
            )

        let points =
            stride(
                from: lowMel,
                through: highMel,
                by:
                    (
                        highMel - lowMel
                    )
                    /
                    Double(
                        config.melFilters + 1
                    )
            )

        let melPoints =
            Array(points)

        let hzPoints =
            melPoints.map(
                melToHz
            )

        var bin =
            hzPoints.map {

                Int(
                    floor(
                        (
                            Double(
                                config.frameSize + 1
                            ) *
                            $0
                        )
                        /
                        config.sampleRate
                    )
                )
            }

        if bin.count <
           config.melFilters + 2 {

            while bin.count <
                  config.melFilters + 2 {

                bin.append(
                    nBins - 1
                )
            }
        }

        var result =
            [[Float]](
                repeating:
                    [Float](
                        repeating: 0,
                        count: nBins
                    ),
                count:
                    config.melFilters
            )

        for m in 0..<config.melFilters {

            let left =
                max(
                    0,
                    bin[m]
                )

            let centre =
                min(
                    nBins - 1,
                    bin[m + 1]
                )

            let right =
                min(
                    nBins - 1,
                    bin[m + 2]
                )

            if centre > left {

                for k in left..<centre {

                    result[m][k] =
                        Float(
                            Double(
                                k - left
                            )
                            /
                            Double(
                                centre - left
                            )
                        )
                }
            }

            if right > centre {

                for k in centre..<right {

                    result[m][k] =
                        Float(
                            Double(
                                right - k
                            )
                            /
                            Double(
                                right - centre
                            )
                        )
                }
            }
        }

        filters = result
    }


    func apply(
        _ spectrum: [Float]
    ) -> [Float] {

        return filters.map {
            filter in

            var value: Float = 0

            vDSP_dotpr(
                filter,
                1,
                spectrum,
                1,
                &value,
                vDSP_Length(
                    min(
                        filter.count,
                        spectrum.count
                    )
                )
            )

            return log(
                max(
                    value,
                    0.00000001
                )
            )
        }
    }
}


// ============================================================
// MARK: - MFCC Engine
// ============================================================

final class MFCCEngine {

    private let config: AudioConfig

    private let fft: FFTEngine

    private let melBank: MelFilterBank

    init?(
        config: AudioConfig
    ) {

        self.config = config

        guard let fft =
                FFTEngine(
                    size: config.frameSize
                )
        else {
            return nil
        }

        self.fft = fft

        self.melBank =
            MelFilterBank(
                config: config
            )
    }


    func mfcc(
        frame: [Float]
    ) -> [Float] {

        let window =
            vDSP.window(
                ofType: Float.self,
                usingSequence:
                    .hanningDenormalized,
                count:
                    frame.count
            )

        let windowed =
            zip(
                frame,
                window
            ).map {
                $0 * $1
            }

        let spectrum =
            fft.powerSpectrum(
                windowed
            )

        let mel =
            melBank.apply(
                spectrum
            )

        var result =
            [Float](
                repeating: 0,
                count: config.mfccCount
            )

        let N =
            config.melFilters

        for k in 0..<config.mfccCount {

            var value: Float = 0

            for n in 0..<N {

                value +=
                    mel[n] *
                    cos(
                        Float.pi *
                        Float(k) *
                        (
                            Float(n) + 0.5
                        )
                        /
                        Float(N)
                    )
            }

            result[k] =
                value
        }

        return result
    }
}


// ============================================================
// MARK: - Speech Feature Extractor
// ============================================================

final class SpeechFeatureExtractor {

    private let config: AudioConfig

    private let mfccEngine:
        MFCCEngine

    init?(
        config: AudioConfig
    ) {

        self.config = config

        guard let engine =
                MFCCEngine(
                    config: config
                )
        else {
            return nil
        }

        self.mfccEngine =
            engine
    }


    func extract(
        audio: [Float]
    ) -> [Float] {

        let frameSize =
            config.frameSize

        let hop =
            config.hopSize

        guard audio.count >= frameSize
        else {
            return []
        }

        var frames =
            [[Float]]()

        var position = 0

        while
            position + frameSize
            <= audio.count {

            let frame =
                Array(
                    audio[
                        position..<(
                            position +
                            frameSize
                        )
                    ]
                )

            frames.append(
                frame
            )

            position += hop
        }

        let mfccFrames =
            frames.map {
                mfccEngine.mfcc(
                    frame: $0
                )
            }

        guard !mfccFrames.isEmpty
        else {
            return []
        }

        var featureVector =
            [Float]()

        //------------------------------------------------------
        // Mean
        //------------------------------------------------------

        for k in 0..<config.mfccCount {

            let values =
                mfccFrames.map {
                    $0[k]
                }

            let mean =
                values.reduce(
                    0,
                    +
                )
                /
                Float(
                    values.count
                )

            featureVector.append(
                mean
            )
        }

        //------------------------------------------------------
        // Standard deviation
        //------------------------------------------------------

        for k in 0..<config.mfccCount {

            let values =
                mfccFrames.map {
                    $0[k]
                }

            let mean =
                values.reduce(
                    0,
                    +
                )
                /
                Float(
                    values.count
                )

            let variance =
                values.reduce(
                    0
                ) {

                    $0 +
                    pow(
                        $1 - mean,
                        2
                    )
                }
                /
                Float(
                    values.count
                )

            featureVector.append(
                sqrt(
                    variance
                )
            )
        }

        return featureVector
    }
}


// ============================================================
// MARK: - Core ML Accent Model
// ============================================================

final class AccentModel {

    private let model:
        MLModel

    let labels: [
        String
    ]

    init?(
        modelURL: URL,
        labels: [String]
    ) {

        do {

            model =
                try MLModel(
                    contentsOf:
                        modelURL
                )

            self.labels =
                labels

        } catch {

            return nil
        }
    }


    func predict(
        features: [Float]
    ) -> AccentResult? {

        do {

            let array =
                try MLMultiArray(
                    shape: [
                        NSNumber(
                            value:
                                features.count
                        )
                    ],
                    dataType:
                        .float32
                )

            for i in
                0..<features.count {

                array[i] =
                    NSNumber(
                        value:
                            features[i]
                    )
            }

            let input =
                try MLDictionaryFeatureProvider(
                    dictionary: [
                        "features":
                            MLFeatureValue(
                                multiArray:
                                    array
                            )
                    ]
                )

            let output =
                try model.prediction(
                    from: input
                )

            guard
                let probabilities =
                    output.featureValue(
                        for:
                            "probabilities"
                    )?.multiArrayValue
            else {

                return nil
            }

            var values =
                [Float]()

            for i in
                0..<probabilities.count {

                values.append(
                    probabilities[
                        i
                    ].floatValue
                )
            }

            guard
                let best =
                    values.indices.max(
                        by: {
                            values[$0] <
                            values[$1]
                        }
                    )
            else {

                return nil
            }

            var probabilityMap =
                [
                    String: Float
                ]()

            for i in
                0..<min(
                    labels.count,
                    values.count
                ) {

                probabilityMap[
                    labels[i]
                ] =
                    values[i]
            }

            return AccentResult(

                label:
                    labels[best],

                confidence:
                    values[best],

                probabilities:
                    probabilityMap,

                embedding:
                    features
            )

        } catch {

            print(
                "Core ML error:",
                error
            )

            return nil
        }
    }
}


// ============================================================
// MARK: - Speaker Adaptation
// ============================================================

final class SpeakerAdaptation {

    private var centroid:
        [Float]?

    private(set) var sampleCount:
        Int = 0

    private let learningRate:
        Float

    init(
        learningRate: Float = 0.05
    ) {

        self.learningRate =
            learningRate
    }


    func update(
        embedding: [Float]
    ) {

        guard !embedding.isEmpty
        else {
            return
        }

        if centroid == nil {

            centroid =
                embedding

            sampleCount = 1

            return
        }

        guard var current =
                centroid
        else {
            return
        }

        for i in
            0..<min(
                current.count,
                embedding.count
            ) {

            current[i] =
                (
                    1 -
                    learningRate
                )
                *
                current[i]
                +
                learningRate
                *
                embedding[i]
        }

        centroid =
            current

        sampleCount += 1
    }


    func similarity(
        to embedding: [Float]
    ) -> Float {

        guard
            let centroid,
            centroid.count ==
                embedding.count
        else {
            return 0
        }

        var dot: Float = 0
        var aNorm: Float = 0
        var bNorm: Float = 0

        for i in
            0..<embedding.count {

            dot +=
                embedding[i] *
                centroid[i]

            aNorm +=
                embedding[i] *
                embedding[i]

            bNorm +=
                centroid[i] *
                centroid[i]
        }

        guard
            aNorm > 0,
            bNorm > 0
        else {
            return 0
        }

        return dot /
            sqrt(
                aNorm *
                bNorm
            )
    }
}


// ============================================================
// MARK: - Live Microphone Engine
// ============================================================

final class SiriAudioEngine {

    private let engine =
        AVAudioEngine()

    private let config =
        AudioConfig()

    private let preprocessor =
        AudioPreprocessor()

    private let extractor:
        SpeechFeatureExtractor

    private let speaker =
        SpeakerAdaptation()

    init?() {

        guard let extractor =
                SpeechFeatureExtractor(
                    config: config
                )
        else {
            return nil
        }

        self.extractor =
            extractor
    }


    func start(
        handler:
            @escaping (
                [Float]
            ) -> Void
    ) throws {

        let input =
            engine.inputNode

        let format =
            input.inputFormat(
                forBus: 0
            )

        input.installTap(
            onBus: 0,
            bufferSize: 1600,
            format: format
        ) {

            [weak self]
            buffer,
            _ in

            guard let self
            else {
                return
            }

            var audio =
                self.preprocessor.mono(
                    buffer
                )

            audio =
                self.preprocessor.normalise(
                    audio
                )

            let features =
                self.extractor.extract(
                    audio: audio
                )

            handler(
                features
            )
        }

        engine.prepare()

        try engine.start()
    }


    func stop() {

        engine.inputNode.removeTap(
            onBus: 0
        )

        engine.stop()
    }


    func learn(
        embedding: [Float]
    ) {

        speaker.update(
            embedding:
                embedding
        )
    }


    func speakerSimilarity(
        embedding: [Float]
    ) -> Float {

        return speaker.similarity(
            to:
                embedding
        )
    }
}




Architecture
                 iPHONE
┌──────────────────────────────────────────────┐
│                                              │
│  Camera                                      │
│    │                                         │
│    ▼                                         │
│  Swift Image Pipeline                        │
│    │                                         │
│    ├── Crop / rotate / lighting              │
│    ├── Apple Vision detection                │
│    ├── OCR                                    │
│    └── Image embeddings                      │
│                 │                            │
│                 ▼                            │
│        ListingInferenceRequest               │
│                 │                            │
└─────────────────┼────────────────────────────┘
                  │
                  ▼
             JULIA ENGINE
┌──────────────────────────────────────────────┐
│                                              │
│  Product classifier                          │
│  Attribute inference                         │
│  Condition inference                         │
│  Category inference                          │
│  Comparable-product model                    │
│  Price estimator                             │
│  Title generator                             │
│  Description generator                       │
│  Confidence engine                           │
│                                              │
└─────────────────┬────────────────────────────┘
                  │
                  ▼
             LISTING OBJECT
                  │
        ┌─────────┼──────────┐
        ▼         ▼          ▼
      Title     Price      Attributes
        │         │          │
        └─────────┼──────────┘
                  ▼
          Swift Listing Editor
                  │
                  ▼
              PUBLISH

The interesting part is that Julia isn't just an API server. I'd use it as the numerical inference/ranking layer: probabilities, comparable-item weighting, price distributions, confidence scoring and optimisation.

1. Swift listing model
import Foundation
import UIKit

struct EcommerceListing: Codable, Identifiable {

    let id: UUID

    var title: String
    var description: String

    var category: String
    var brand: String?
    var model: String?

    var condition: String

    var attributes: [String: String]

    var suggestedPrice: Double
    var priceRangeLow: Double
    var priceRangeHigh: Double

    var confidence: Double

    var detectedText: [String]

    var imageURL: String?
}

The seller ultimately gets something like:

PHOTO
 ↓

"Apple iPhone 15 Pro 256GB Natural Titanium"

Category:
Electronics / Mobile Phones

Condition:
Used — Good

Storage:
256 GB

Colour:
Natural Titanium

Suggested price:
£649

Confidence:
94%

Description:
Apple iPhone 15 Pro with 256GB storage...

And they simply tap Publish.

2. Swift photo capture
import SwiftUI
import PhotosUI

struct ProductCameraView: View {

    @State private var selectedItem:
        PhotosPickerItem?

    @State private var image:
        UIImage?

    @State private var processing = false

    var body: some View {

        VStack(spacing: 24) {

            if let image {

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 28,
                            style: .continuous
                        )
                    )
                    .padding()

            } else {

                ContentUnavailableView(
                    "Photograph your product",
                    systemImage: "camera",
                    description:
                        Text("One photo is enough to start a listing.")
                )
            }

            PhotosPicker(
                selection: $selectedItem,
                matching: .images
            ) {

                Label(
                    "Choose Product Photo",
                    systemImage: "camera"
                )
                .font(
                    .system(
                        size: 18,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    .thinMaterial,
                    in: Capsule()
                )
            }
            .padding(.horizontal)

            if processing {

                ProgressView(
                    "Building listing…"
                )
            }
        }
        .task(id: selectedItem) {

            guard let selectedItem else {
                return
            }

            do {

                if let data =
                    try await selectedItem
                    .loadTransferable(
                        type: Data.self
                    ) {

                    image = UIImage(
                        data: data
                    )
                }

            } catch {

                print(error)
            }
        }
    }
}

For the production version I'd replace the photo picker with a dedicated AVCaptureSession camera so that we can run live product detection while the seller is pointing the camera.

3. Swift image preprocessing

The phone should do cheap operations locally before sending anything to Julia.

import UIKit
import Vision

struct ProductImageProcessor {

    func process(
        image: UIImage
    ) async throws -> ProcessedProductImage {

        guard let cgImage = image.cgImage
        else {
            throw ImageError.invalidImage
        }

        let text = try await detectText(
            cgImage: cgImage
        )

        let objects = try await detectObjects(
            cgImage: cgImage
        )

        return ProcessedProductImage(
            image: image,
            detectedText: text,
            detectedObjects: objects
        )
    }

    private func detectText(
        cgImage: CGImage
    ) async throws -> [String] {

        try await withCheckedThrowingContinuation {
            continuation in

            let request =
                VNRecognizeTextRequest {

                    request,
                    error in

                    if let error {
                        continuation.resume(
                            throwing: error
                        )
                        return
                    }

                    let observations =
                        request.results
                        as? [VNRecognizedTextObservation]
                        ?? []

                    let text =
                        observations.compactMap {
                            $0.topCandidates(1).first?.string
                        }

                    continuation.resume(
                        returning: text
                    )
                }

            request.recognitionLevel = .accurate

            let handler =
                VNImageRequestHandler(
                    cgImage: cgImage
                )

            do {
                try handler.perform(
                    [request]
                )
            } catch {
                continuation.resume(
                    throwing: error
                )
            }
        }
    }

    private func detectObjects(
        cgImage: CGImage
    ) async throws -> [DetectedObject] {

        try await withCheckedThrowingContinuation {
            continuation in

            let request =
                VNGenerateObjectnessBasedSaliencyImageRequest {
                    request,
                    error in

                    if let error {
                        continuation.resume(
                            throwing: error
                        )
                        return
                    }

                    let observations =
                        request.results
                        as? [VNSaliencyImageObservation]
                        ?? []

                    let objects =
                        observations.map {
                            DetectedObject(
                                confidence:
                                    Double(
                                        $0.salientObjects?
                                            .first?
                                            .confidence
                                        ?? 0
                                    )
                            )
                        }

                    continuation.resume(
                        returning: objects
                    )
                }

            let handler =
                VNImageRequestHandler(
                    cgImage: cgImage
                )

            do {
                try handler.perform(
                    [request]
                )
            } catch {
                continuation.resume(
                    throwing: error
                )
            }
        }
    }
}

struct ProcessedProductImage {

    let image: UIImage
    let detectedText: [String]
    let detectedObjects: [DetectedObject]
}

struct DetectedObject {

    let confidence: Double
}

enum ImageError: Error {
    case invalidImage
}

The next level would use a custom Core ML/Vision model for actual product categories rather than generic objectness.

4. Send the intelligence request to Julia

Swift should send structured information, not just blindly upload the image.

struct ListingInferenceRequest: Codable {

    let detectedText: [String]

    let detectedObjects: [ObjectSignal]

    let imageEmbedding: [Float]?

    let marketplace: String

    let currency: String
}

struct ObjectSignal: Codable {

    let label: String
    let confidence: Double
}

Then:

actor ListingInferenceClient {

    let endpoint =
        URL(
            string:
                "https://api.example.com/listing/infer"
        )!

    func infer(
        request: ListingInferenceRequest
    ) async throws -> EcommerceListing {

        var urlRequest =
            URLRequest(
                url: endpoint
            )

        urlRequest.httpMethod = "POST"

        urlRequest.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        urlRequest.httpBody =
            try JSONEncoder()
                .encode(request)

        let (
            data,
            response
        ) =
            try await URLSession.shared.data(
                for: urlRequest
            )

        guard
            let http =
                response as? HTTPURLResponse,
            (200..<300).contains(
                http.statusCode
            )
        else {
            throw URLError(
                .badServerResponse
            )
        }

        return try JSONDecoder()
            .decode(
                EcommerceListing.self,
                from: data
            )
    }
}
5. Julia becomes the commerce engine

This is where I think Julia is particularly interesting.

Use Julia for:

Image signals
     ↓
Feature vector
     ↓
Product classification
     ↓
Attribute inference
     ↓
Comparable products
     ↓
Price distribution
     ↓
Listing optimisation

A basic Julia engine:

module ListingEngine

using Statistics
using LinearAlgebra
using JSON3

export infer_listing

struct ProductSignal
    label::String
    confidence::Float64
end

struct ListingPrediction

    category::String
    brand::Union{String,Nothing}
    model::Union{String,Nothing}

    condition::String

    attributes::Dict{String,String}

    price::Float64
    low::Float64
    high::Float64

    confidence::Float64
end


function weighted_mean(
    values,
    weights
)

    return sum(
        values .* weights
    ) / sum(weights)

end


function price_estimate(
    comparable_prices,
    similarity
)

    weights =
        similarity .^ 3

    centre =
        weighted_mean(
            comparable_prices,
            weights
        )

    spread =
        std(
            comparable_prices
        )

    low =
        max(
            0,
            centre - 0.75 * spread
        )

    high =
        centre + 0.75 * spread

    return (
        centre,
        low,
        high
    )
end


function classify_category(
    text::Vector{String}
)

    joined =
        lowercase(
            join(
                text,
                " "
            )
        )

    if occursin(
        "iphone",
        joined
    )

        return "Electronics / Smartphones"

    elseif occursin(
        "nike",
        joined
    )

        return "Fashion / Footwear"

    elseif occursin(
        "lego",
        joined
    )

        return "Toys / Construction"

    else

        return "General Merchandise"

    end

end


function infer_condition(
    text::Vector{String}
)

    joined =
        lowercase(
            join(
                text,
                " "
            )
        )

    if occursin(
        "new",
        joined
    )

        return "New"

    elseif occursin(
        "excellent",
        joined
    )

        return "Used — Excellent"

    else

        return "Used — Good"

    end

end


function infer_listing(
    text::Vector{String},
    comparable_prices::Vector{Float64},
    similarities::Vector{Float64}
)

    category =
        classify_category(
            text
        )

    condition =
        infer_condition(
            text
        )

    price,
    low,
    high =
        price_estimate(
            comparable_prices,
            similarities
        )

    confidence =
        mean(
            similarities
        )

    attributes =
        Dict(
            "source" => "photo",
            "condition_confidence" =>
                string(confidence)
        )

    return ListingPrediction(
        category,
        nothing,
        nothing,
        condition,
        attributes,
        price,
        low,
        high,
        confidence
    )

end

end

That is the numerical core. In the real system, the classify_category section becomes a trained model rather than keyword matching.

6. Julia price intelligence

This is where I'd make the system considerably more sophisticated.

Instead of:

average price = £500

I'd calculate:

                 Comparable products
                        │
              ┌─────────┴─────────┐
              │                   │
           similarity          recency
              │                   │
              └─────────┬─────────┘
                        │
                  weighted price
                        │
             ┌──────────┴──────────┐
             │                     │
          quick sale             maximum
             │                     │
          £575                    £699
             │                     │
             └─────────┬───────────┘
                       │
                 suggested £649

Julia code:

function adaptive_price(
    prices::Vector{Float64},
    similarity::Vector{Float64},
    age_days::Vector{Float64}
)

    similarity_weight =
        similarity .^ 4

    recency_weight =
        exp.(-age_days ./ 30)

    weights =
        similarity_weight .* recency_weight

    fair_value =
        sum(
            prices .* weights
        ) / sum(weights)

    volatility =
        std(prices)

    quick_sale =
        fair_value -
        0.5 * volatility

    premium =
        fair_value +
        0.5 * volatility

    return (
        fair_value,
        quick_sale,
        premium
    )

end

That gives the app a pricing distribution rather than a fake precision number.

7. Automatic title generation

I'd make the listing engine construct the title from the inferred product ontology:

function generate_title(
    brand,
    model,
    capacity,
    condition
)

    components =
        String[]

    if brand !== nothing
        push!(components, brand)
    end

    if model !== nothing
        push!(components, model)
    end

    if capacity !== nothing
        push!(components, capacity)
    end

    push!(
        components,
        condition
    )

    return join(
        components,
        " "
    )

end

So the pipeline becomes:

PHOTO
 │
 ├── OCR
 │     └── "Apple / iPhone 15 Pro / 256GB"
 │
 ├── Vision
 │     └── smartphone
 │
 ├── Image embedding
 │     └── product similarity
 │
 └── Julia
       │
       ├── category
       ├── brand
       ├── model
       ├── attributes
       ├── condition
       ├── comparables
       ├── price
       └── confidence
             │
             ▼
       AUTOMATIC LISTING
And I'd make the iPhone UI feel almost instantaneous

The UX shouldn't wait for Julia to finish.

0.00s       Photo captured
 │
 ▼
0.05s       Image appears
 │
 ▼
0.10s       "Product detected"
 │
 ▼
0.20s       OCR attributes appear
 │
 ▼
0.40s       Category appears
 │
 ▼
0.60s       Title appears
 │
 ▼
0.80s       Price estimate appears
 │
 ▼
1.00s+      Description/comparables complete

The UI can therefore progressively construct the listing:

struct AutoListingView: View {

    @State private var listing:
        EcommerceListing?

    @State private var phase:
        ListingPhase = .analysing

    var body: some View {

        ZStack {

            Color.black
                .ignoresSafeArea()

            VStack(
                alignment: .leading,
                spacing: 18
            ) {

                Text(
                    phase == .analysing
                    ? "Understanding your product…"
                    : "Your listing"
                )
                .font(
                    .system(
                        size: 34,
                        weight: .bold,
                        design: .rounded
                    )
                )

                if let listing {

                    ListingCard(
                        listing: listing
                    )
                    .transition(
                        .scale(scale: 0.94)
                        .combined(
                            with: .opacity
                        )
                    )

                } else {

                    ProductAnalysisAnimation()
                }

                Spacer()

                if listing != nil {

                    Button("Publish Listing") {
                        publish()
                    }
                    .font(
                        .system(
                            size: 18,
                            weight: .semibold
                        )
                    )
                    .frame(
                        maxWidth: .infinity
                    )
                    .padding()
                    .background(
                        .white,
                        in: Capsule()
                    )
                    .foregroundStyle(.black)
                }
            }
            .padding(22)
        }
    }

    private func publish() {
        // Marketplace API
    }
}

enum ListingPhase {
    case analysing
    case ready
}
The bigger idea

I'd actually make this an “image-native commerce OS” rather than merely an auto-listing feature.

The seller's workflow becomes:

Photograph → AI understands → verify → publish.

And Julia can eventually learn from every completed transaction:

photo
  ↓
prediction
  ↓
listing
  ↓
views
  ↓
offers
  ↓
sale
  ↓
actual price
  ↓
Julia training dataset
  ↓
better future price prediction


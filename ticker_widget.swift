1. BitcoinTickerWidget.swift
import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct BitcoinPriceEntry: TimelineEntry {

    let date: Date
    let priceGBP: Double?
    let change24h: Double?
    let lastUpdated: Date
    let error: String?

    static var placeholder: BitcoinPriceEntry {
        BitcoinPriceEntry(
            date: Date(),
            priceGBP: 87_420.50,
            change24h: 2.41,
            lastUpdated: Date(),
            error: nil
        )
    }
}

// MARK: - API Model

private struct CoinGeckoResponse: Decodable {

    struct Bitcoin: Decodable {

        let gbp: Double
        let gbp24hChange: Double?

        enum CodingKeys: String, CodingKey {
            case gbp
            case gbp24hChange = "gbp_24h_change"
        }
    }

    let bitcoin: Bitcoin
}

// MARK: - Price Service

actor BitcoinPriceService {

    static let shared = BitcoinPriceService()

    private let endpoint =
        URL(
            string:
                "https://api.coingecko.com/api/v3/simple/price" +
                "?ids=bitcoin" +
                "&vs_currencies=gbp" +
                "&include_24hr_change=true"
        )!

    func fetchPrice() async throws
        -> (price: Double, change: Double?) {

        var request =
            URLRequest(
                url: endpoint
            )

        request.httpMethod = "GET"

        request.timeoutInterval = 10

        request.setValue(
            "Aureom-BitcoinTicker/1.0",
            forHTTPHeaderField:
                "User-Agent"
        )

        let configuration =
            URLSessionConfiguration.ephemeral

        configuration.waitsForConnectivity = true

        let session =
            URLSession(
                configuration:
                    configuration
            )

        let (
            data,
            response
        ) =
            try await session.data(
                for: request
            )

        guard
            let http =
                response as? HTTPURLResponse,
            200..<300 ~= http.statusCode
        else {
            throw URLError(
                .badServerResponse
            )
        }

        let decoded =
            try JSONDecoder()
                .decode(
                    CoinGeckoResponse.self,
                    from: data
                )

        return (
            decoded.bitcoin.gbp,
            decoded.bitcoin.gbp24hChange
        )
    }
}

// MARK: - Provider

struct BitcoinTickerProvider:
    TimelineProvider {

    func placeholder(
        in context: Context
    ) -> BitcoinPriceEntry {

        .placeholder
    }

    func getSnapshot(
        in context: Context,
        completion:
            @escaping (
                BitcoinPriceEntry
            ) -> Void
    ) {

        Task {

            let entry =
                await loadEntry()

            completion(entry)
        }
    }

    func getTimeline(
        in context: Context,
        completion:
            @escaping (
                Timeline<BitcoinPriceEntry>
            ) -> Void
    ) {

        Task {

            let entry =
                await loadEntry()

            // Ask WidgetKit to refresh in approximately
            // five minutes. iOS ultimately decides the
            // actual refresh timing.
            let nextRefresh =
                Calendar.current.date(
                    byAdding:
                        .minute,
                    value:
                        5,
                    to:
                        Date()
                )
                ?? Date().addingTimeInterval(
                    300
                )

            let timeline =
                Timeline(
                    entries:
                        [entry],
                    policy:
                        .after(
                            nextRefresh
                        )
                )

            completion(timeline)
        }
    }

    private func loadEntry()
        async -> BitcoinPriceEntry {

        do {

            let result =
                try await BitcoinPriceService
                    .shared
                    .fetchPrice()

            return BitcoinPriceEntry(
                date:
                    Date(),
                priceGBP:
                    result.price,
                change24h:
                    result.change,
                lastUpdated:
                    Date(),
                error:
                    nil
            )

        } catch {

            return BitcoinPriceEntry(
                date:
                    Date(),
                priceGBP:
                    nil,
                change24h:
                    nil,
                lastUpdated:
                    Date(),
                error:
                    error.localizedDescription
            )
        }
    }
}

// MARK: - Widget View

struct BitcoinTickerWidgetView:
    View {

    var entry:
        BitcoinTickerProvider.Entry

    @Environment(
        \.widgetFamily
    )
    private var family

    var body: some View {

        VStack(
            alignment:
                .leading,
            spacing:
                8
        ) {

            header

            Spacer(
                minLength:
                    2
            )

            price

            Spacer(
                minLength:
                    2
            )

            footer
        }
        .padding(
            family == .systemSmall
                ? 14
                : 18
        )
        .containerBackground(
            for:
                .widget
        ) {

            LinearGradient(
                colors: [
                    Color.black,
                    Color(
                        red: 0.08,
                        green: 0.05,
                        blue: 0.02
                    )
                ],
                startPoint:
                    .topLeading,
                endPoint:
                    .bottomTrailing
            )
        }
    }

    private var header:
        some View {

        HStack {

            Text("₿")
                .font(
                    .system(
                        size: 20,
                        weight:
                            .bold,
                        design:
                            .rounded
                    )
                )
                .foregroundStyle(
                    Color(
                        red: 1.0,
                        green: 0.56,
                        blue: 0.05
                    )
                )

            Text("BITCOIN")
                .font(
                    .system(
                        size: 12,
                        weight:
                            .bold,
                        design:
                            .rounded
                    )
                )
                .tracking(1.5)

            Spacer()

            Circle()
                .fill(
                    Color.green
                )
                .frame(
                    width: 6,
                    height: 6
                )
        }
        .foregroundStyle(
            .white
        )
    }

    @ViewBuilder
    private var price:
        some View {

        if let price =
            entry.priceGBP {

            VStack(
                alignment:
                    .leading,
                spacing:
                    2
            ) {

                Text(
                    price,
                    format:
                        .currency(
                            code:
                                "GBP"
                        )
                )
                .font(
                    .system(
                        size:
                            family ==
                            .systemSmall
                            ? 25
                            : 31,
                        weight:
                            .bold,
                        design:
                            .rounded
                    )
                )
                .minimumScaleFactor(
                    0.65
                )
                .foregroundStyle(
                    .white
                )

                if let change =
                    entry.change24h {

                    Text(
                        change >= 0
                            ? "+\(change, specifier: "%.2f")%"
                            : "\(change, specifier: "%.2f")%"
                    )
                    .font(
                        .system(
                            size: 13,
                            weight:
                                .semibold,
                            design:
                                .rounded
                        )
                    )
                    .foregroundStyle(
                        change >= 0
                            ? Color.green
                            : Color.red
                    )
                }
            }

        } else {

            Text("BTC unavailable")
                .font(
                    .headline
                )
                .foregroundStyle(
                    .white
                )
        }
    }

    private var footer:
        some View {

        HStack {

            Text("BTC / GBP")
                .font(
                    .system(
                        size: 9,
                        weight:
                            .medium,
                        design:
                            .monospaced
                    )
                )
                .foregroundStyle(
                    .white.opacity(
                        0.55
                    )
                )

            Spacer()

            Text(
                entry.lastUpdated,
                style:
                    .time
            )
            .font(
                .system(
                    size: 9,
                    design:
                        .monospaced
                )
            )
            .foregroundStyle(
                .white.opacity(
                    0.45
                )
            )
        }
    }
}

// MARK: - Widget Configuration

struct BitcoinTickerWidget:
    Widget {

    let kind =
        "BitcoinTickerWidget"

    var body: some WidgetConfiguration {

        StaticConfiguration(
            kind:
                kind,
            provider:
                BitcoinTickerProvider()
        ) { entry in

            BitcoinTickerWidgetView(
                entry:
                    entry
            )
        }
        .configurationDisplayName(
            "Bitcoin Ticker"
        )
        .description(
            "Live Bitcoin price in GBP."
        )
        .supportedFamilies([
            .systemSmall,
            .systemMedium
        ])
    }
}

// MARK: - Widget Bundle

@main
struct AureomBitcoinWidgets:
    WidgetBundle {

    var body: some Widget {

        BitcoinTickerWidget()
    }
}

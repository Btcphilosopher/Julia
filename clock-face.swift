import SwiftUI
import WidgetKit

// MARK: - Clock Entry

struct ClockEntry: TimelineEntry {
    let date: Date
}

// MARK: - Timeline Provider

struct ClockProvider: TimelineProvider {

    func placeholder(
        in context: Context
    ) -> ClockEntry {
        ClockEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ClockEntry) -> Void
    ) {
        completion(
            ClockEntry(date: Date())
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (
            Timeline<ClockEntry>
        ) -> Void
    ) {

        let now = Date()

        // Generate one entry per second for the
        // currently rendered timeline.
        //
        // WidgetKit may coalesce or ignore these
        // refresh requests. They do NOT guarantee
        // a continuously animated Home Screen widget.

        var entries: [ClockEntry] = []

        for second in 0..<60 {

            let date =
                now.addingTimeInterval(
                    TimeInterval(second)
                )

            entries.append(
                ClockEntry(date: date)
            )
        }

        let timeline =
            Timeline(
                entries: entries,
                policy: .after(
                    now.addingTimeInterval(60)
                )
            )

        completion(timeline)
    }
}

// MARK: - Clock Face

struct AnalogueClockView: View {

    let date: Date

    private let calendar =
        Calendar.current

    var body: some View {

        GeometryReader { geometry in

            let size =
                min(
                    geometry.size.width,
                    geometry.size.height
                )

            let centre =
                CGPoint(
                    x: geometry.size.width / 2,
                    y: geometry.size.height / 2
                )

            ZStack {

                // Face
                Circle()
                    .fill(
                        Color.black
                    )

                // Outer bezel
                Circle()
                    .stroke(
                        Color.white.opacity(0.18),
                        lineWidth: 1
                    )

                // Hour markers
                ForEach(
                    0..<60,
                    id: \.self
                ) { tick in

                    Rectangle()
                        .fill(
                            tick % 5 == 0
                                ? Color.white
                                : Color.white.opacity(0.28)
                        )
                        .frame(
                            width:
                                tick % 5 == 0
                                    ? 2
                                    : 1,
                            height:
                                tick % 5 == 0
                                    ? size * 0.055
                                    : size * 0.025
                        )
                        .offset(
                            y:
                                -size * 0.42
                        )
                        .rotationEffect(
                            .degrees(
                                Double(tick) * 6
                            )
                        )
                }

                // Hour hand
                ClockHand(
                    angle:
                        hourAngle,
                    length:
                        size * 0.25,
                    width:
                        size * 0.035,
                    colour:
                        .white
                )

                // Minute hand
                ClockHand(
                    angle:
                        minuteAngle,
                    length:
                        size * 0.34,
                    width:
                        size * 0.022,
                    colour:
                        .white
                )

                // Second hand
                ClockHand(
                    angle:
                        secondAngle,
                    length:
                        size * 0.38,
                    width:
                        size * 0.009,
                    colour:
                        Color(
                            red: 1.0,
                            green: 0.35,
                            blue: 0.05
                        )
                )

                // Centre pin
                Circle()
                    .fill(
                        Color(
                            red: 1.0,
                            green: 0.35,
                            blue: 0.05
                        )
                    )
                    .frame(
                        width:
                            size * 0.045,
                        height:
                            size * 0.045
                    )
            }
            .frame(
                width:
                    geometry.size.width,
                height:
                    geometry.size.height
            )
        }
        .aspectRatio(
            1,
            contentMode:
                .fit
        )
    }

    // MARK: Angles

    private var secondAngle:
        Double {

        let components =
            calendar.dateComponents(
                [
                    .second,
                    .nanosecond
                ],
                from:
                    date
            )

        let seconds =
            Double(
                components.second ?? 0
            )

        let nanoseconds =
            Double(
                components.nanosecond ?? 0
            )

        let fractionalSecond =
            nanoseconds /
            1_000_000_000

        return (
            seconds +
            fractionalSecond
        ) * 6
    }

    private var minuteAngle:
        Double {

        let components =
            calendar.dateComponents(
                [
                    .hour,
                    .minute,
                    .second
                ],
                from:
                    date
            )

        let minutes =
            Double(
                components.minute ?? 0
            )

        let seconds =
            Double(
                components.second ?? 0
            )

        return (
            minutes +
            seconds / 60
        ) * 6
    }

    private var hourAngle:
        Double {

        let components =
            calendar.dateComponents(
                [
                    .hour,
                    .minute,
                    .second
                ],
                from:
                    date
            )

        let hour =
            Double(
                components.hour ?? 0
            )
            .truncatingRemainder(
                dividingBy: 12
            )

        let minute =
            Double(
                components.minute ?? 0
            )

        let second =
            Double(
                components.second ?? 0
            )

        return (
            hour +
            minute / 60 +
            second / 3600
        ) * 30
    }
}

// MARK: - Hand

struct ClockHand:
    View {

    let angle: Double
    let length: CGFloat
    let width: CGFloat
    let colour: Color

    var body: some View {

        GeometryReader { geometry in

            Rectangle()
                .fill(colour)
                .frame(
                    width: width,
                    height: length
                )
                .clipShape(
                    Capsule()
                )
                .position(
                    x:
                        geometry.size.width / 2,
                    y:
                        geometry.size.height / 2 -
                        length / 2
                )
                .rotationEffect(
                    .degrees(angle),
                    anchor:
                        UnitPoint(
                            x: 0.5,
                            y: 1.0
                        )
                )
        }
    }
}

// MARK: - Widget

struct AureomClockWidget:
    Widget {

    let kind =
        "AureomClockWidget"

    var body:
        some WidgetConfiguration {

        StaticConfiguration(
            kind:
                kind,
            provider:
                ClockProvider()
        ) { entry in

            AnalogueClockView(
                date:
                    entry.date
            )
            .containerBackground(
                for:
                    .widget
            ) {
                Color.black
            }
        }
        .configurationDisplayName(
            "Aureom Clock"
        )
        .description(
            "A precision analogue clock."
        )
        .supportedFamilies([
            .systemSmall,
            .systemMedium
        ])
    }
}

// MARK: - Widget Bundle

@main
struct AureomClockBundle:
    WidgetBundle {

    var body: some Widget {
        AureomClockWidget()
    }
}

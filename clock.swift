```swift
import SwiftUI
import Foundation
import Combine
import UserNotifications

// ============================================================
// APPLE CLOCK ENGINE
// ============================================================

@MainActor
final class ClockEngine: ObservableObject {

    // --------------------------------------------------------
    // MARK: Published Time
    // --------------------------------------------------------

    @Published private(set) var now = Date()

    @Published private(set) var calendar =
        Calendar.current

    @Published private(set) var timeZone =
        TimeZone.current

    private var timer: Timer?

    // --------------------------------------------------------
    // MARK: Start
    // --------------------------------------------------------

    func start() {

        stop()

        update()

        timer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in

            Task { @MainActor in
                self?.update()
            }
        }
    }

    func stop() {

        timer?.invalidate()
        timer = nil
    }

    private func update() {

        now = Date()

        calendar.timeZone =
            timeZone
    }

    deinit {

        timer?.invalidate()
    }

    // --------------------------------------------------------
    // MARK: Components
    // --------------------------------------------------------

    var hour: Int {
        calendar.component(
            .hour,
            from: now
        )
    }

    var minute: Int {
        calendar.component(
            .minute,
            from: now
        )
    }

    var second: Int {
        calendar.component(
            .second,
            from: now
        )
    }

    var nanosecond: Int {

        calendar.component(
            .nanosecond,
            from: now
        )
    }

    var secondProgress: Double {

        Double(second) +
        Double(nanosecond) / 1_000_000_000
    }

    var minuteProgress: Double {

        Double(minute) +
        secondProgress / 60.0
    }

    var hourProgress: Double {

        Double(hour % 12) +
        minuteProgress / 60.0
    }

    // --------------------------------------------------------
    // MARK: Formatting
    // --------------------------------------------------------

    func formattedTime(
        use24Hour: Bool = false
    ) -> String {

        let formatter =
            DateFormatter()

        formatter.locale =
            Locale.current

        formatter.timeZone =
            timeZone

        formatter.dateFormat =
            use24Hour
            ? "HH:mm:ss"
            : "h:mm:ss a"

        return formatter.string(
            from: now
        )
    }

    func formattedDate() -> String {

        let formatter =
            DateFormatter()

        formatter.locale =
            Locale.current

        formatter.timeZone =
            timeZone

        formatter.dateStyle =
            .full

        return formatter.string(
            from: now
        )
    }
}

// ============================================================
// CLOCK FACE
// ============================================================

enum ClockFace: String, CaseIterable {

    case digital
    case analog
    case minimal
    case system
}

// ============================================================
// DIGITAL CLOCK
// ============================================================

struct DigitalClockView: View {

    @ObservedObject
    var clock: ClockEngine

    var use24Hour = false

    var body: some View {

        VStack(spacing: 8) {

            Text(
                clock.formattedTime(
                    use24Hour: use24Hour
                )
            )
            .font(
                .system(
                    size: 58,
                    weight: .medium,
                    design: .rounded
                )
            )
            .monospacedDigit()

            Text(
                clock.formattedDate()
            )
            .font(.subheadline)
            .foregroundStyle(
                .secondary
            )
        }
    }
}

// ============================================================
// ANALOG CLOCK
// ============================================================

struct AnalogClockView: View {

    @ObservedObject
    var clock: ClockEngine

    var body: some View {

        GeometryReader { geometry in

            let size =
                min(
                    geometry.size.width,
                    geometry.size.height
                )

            ZStack {

                Circle()
                    .fill(
                        .regularMaterial
                    )

                Circle()
                    .stroke(
                        .secondary.opacity(0.25),
                        lineWidth: 2
                    )

                // ------------------------------------------------
                // Hour markers
                // ------------------------------------------------

                ForEach(
                    0..<60,
                    id: \.self
                ) { index in

                    Rectangle()
                        .fill(
                            index % 5 == 0
                            ? Color.primary
                            : Color.secondary.opacity(0.4)
                        )
                        .frame(
                            width:
                                index % 5 == 0
                                ? 2.5
                                : 1,
                            height:
                                index % 5 == 0
                                ? size * 0.07
                                : size * 0.035
                        )
                        .offset(
                            y:
                                -size * 0.43
                        )
                        .rotationEffect(
                            .degrees(
                                Double(index) * 6
                            )
                        )
                }

                // ------------------------------------------------
                // Hour hand
                // ------------------------------------------------

                ClockHand(
                    length: size * 0.27,
                    width: 6,
                    angle:
                        clock.hourProgress *
                        30
                )

                // ------------------------------------------------
                // Minute hand
                // ------------------------------------------------

                ClockHand(
                    length: size * 0.36,
                    width: 4,
                    angle:
                        clock.minuteProgress *
                        6
                )

                // ------------------------------------------------
                // Second hand
                // ------------------------------------------------

                Rectangle()
                    .fill(.red)
                    .frame(
                        width: 1.5,
                        height: size * 0.40
                    )
                    .offset(
                        y: -size * 0.20
                    )
                    .rotationEffect(
                        .degrees(
                            clock.secondProgress * 6
                        )
                    )

                Circle()
                    .fill(.red)
                    .frame(
                        width: 10,
                        height: 10
                    )
            }
            .frame(
                width: size,
                height: size
            )
        }
        .aspectRatio(
            1,
            contentMode: .fit
        )
    }
}

// ============================================================
// CLOCK HAND
// ============================================================

struct ClockHand: View {

    let length: Double
    let width: Double
    let angle: Double

    var body: some View {

        Rectangle()
            .fill(.primary)
            .frame(
                width: width,
                height: length
            )
            .offset(
                y: -length / 2
            )
            .rotationEffect(
                .degrees(angle)
            )
    }
}

// ============================================================
// WORLD CLOCK
// ============================================================

struct WorldClock {

    let identifier: String
    let city: String
    let timeZone: TimeZone

    func date(
        relativeTo date: Date
    ) -> Date {

        date
    }
}

@MainActor
final class WorldClockEngine:
    ObservableObject {

    @Published
    private(set) var clocks: [WorldClock] = []

    init() {

        addDefaultClocks()
    }

    private func addDefaultClocks() {

        let zones: [
            (String, String, String)
        ] = [

            (
                "london",
                "London",
                "Europe/London"
            ),

            (
                "new_york",
                "New York",
                "America/New_York"
            ),

            (
                "san_francisco",
                "San Francisco",
                "America/Los_Angeles"
            ),

            (
                "tokyo",
                "Tokyo",
                "Asia/Tokyo"
            ),

            (
                "singapore",
                "Singapore",
                "Asia/Singapore"
            ),

            (
                "sydney",
                "Sydney",
                "Australia/Sydney"
            )
        ]

        clocks =
            zones.compactMap {

                guard
                    let zone =
                        TimeZone(
                            identifier: $0.2
                        )
                else {
                    return nil
                }

                return WorldClock(
                    identifier: $0.0,
                    city: $0.1,
                    timeZone: zone
                )
            }
    }

    func formattedTime(
        for clock: WorldClock,
        date: Date = Date()
    ) -> String {

        let formatter =
            DateFormatter()

        formatter.timeZone =
            clock.timeZone

        formatter.dateFormat =
            "HH:mm"

        return formatter.string(
            from: date
        )
    }
}

// ============================================================
// ALARM
// ============================================================

struct ClockAlarm:
    Identifiable,
    Codable {

    let id: UUID

    var hour: Int
    var minute: Int

    var label: String

    var enabled: Bool

    var repeats: Bool

    var weekdays: Set<Int>

    init(
        hour: Int,
        minute: Int,
        label: String = "Alarm",
        enabled: Bool = true,
        repeats: Bool = false,
        weekdays: Set<Int> = []
    ) {

        self.id =
            UUID()

        self.hour =
            hour

        self.minute =
            minute

        self.label =
            label

        self.enabled =
            enabled

        self.repeats =
            repeats

        self.weekdays =
            weekdays
    }
}

// ============================================================
// ALARM ENGINE
// ============================================================

@MainActor
final class AlarmEngine:
    ObservableObject {

    @Published
    var alarms: [ClockAlarm] = []

    func addAlarm(
        hour: Int,
        minute: Int,
        label: String = "Alarm"
    ) {

        alarms.append(
            ClockAlarm(
                hour: hour,
                minute: minute,
                label: label
            )
        )

        schedule(
            alarms.last!
        )
    }

    func deleteAlarm(
        _ alarm: ClockAlarm
    ) {

        alarms.removeAll {
            $0.id == alarm.id
        }
    }

    func toggle(
        _ alarm: ClockAlarm
    ) {

        guard
            let index =
                alarms.firstIndex(
                    where: {
                        $0.id == alarm.id
                    }
                )
        else {
            return
        }

        alarms[index].enabled.toggle()

        if alarms[index].enabled {

            schedule(
                alarms[index]
            )
        }
    }

    private func schedule(
        _ alarm: ClockAlarm
    ) {

        let center =
            UNUserNotificationCenter.current()

        let content =
            UNMutableNotificationContent()

        content.title =
            alarm.label

        content.body =
            "It's time."

        content.sound =
            .default

        var components =
            DateComponents()

        components.hour =
            alarm.hour

        components.minute =
            alarm.minute

        let trigger =
            UNCalendarNotificationTrigger(
                dateMatching:
                    components,
                repeats:
                    alarm.repeats
            )

        let request =
            UNNotificationRequest(
                identifier:
                    alarm.id.uuidString,
                content:
                    content,
                trigger:
                    trigger
            )

        center.add(
            request
        )
    }
}

// ============================================================
// STOPWATCH
// ============================================================

@MainActor
final class StopwatchEngine:
    ObservableObject {

    @Published
    private(set) var elapsed: TimeInterval = 0

    @Published
    private(set) var running = false

    private var startDate: Date?
    private var accumulated: TimeInterval = 0

    private var timer: Timer?

    func start() {

        guard !running else {
            return
        }

        running = true

        startDate =
            Date()

        timer =
            Timer.scheduledTimer(
                withTimeInterval: 0.01,
                repeats: true
            ) {
                [weak self] _ in

                Task { @MainActor in

                    guard
                        let self,
                        let startDate =
                            self.startDate
                    else {
                        return
                    }

                    self.elapsed =
                        self.accumulated +
                        Date().timeIntervalSince(
                            startDate
                        )
                }
            }
    }

    func pause() {

        guard running else {
            return
        }

        if let startDate {

            accumulated +=
                Date().timeIntervalSince(
                    startDate
                )
        }

        running = false

        self.startDate =
            nil

        timer?.invalidate()
        timer = nil
    }

    func reset() {

        pause()

        accumulated = 0
        elapsed = 0
    }
}

// ============================================================
// TIMER
// ============================================================

@MainActor
final class CountdownTimerEngine:
    ObservableObject {

    @Published
    private(set) var remaining: TimeInterval = 0

    @Published
    private(set) var running = false

    private var timer: Timer?

    func set(
        seconds: TimeInterval
    ) {

        remaining =
            max(
                0,
                seconds
            )
    }

    func start() {

        guard
            remaining > 0,
            !running
        else {
            return
        }

        running = true

        timer =
            Timer.scheduledTimer(
                withTimeInterval: 0.1,
                repeats: true
            ) {
                [weak self] _ in

                Task { @MainActor in

                    guard
                        let self
                    else {
                        return
                    }

                    self.remaining -= 0.1

                    if self.remaining <= 0 {

                        self.remaining = 0

                        self.stop()

                        self.fireCompletion()
                    }
                }
            }
    }

    func stop() {

        running = false

        timer?.invalidate()
        timer = nil
    }

    func reset(
        seconds: TimeInterval
    ) {

        stop()

        remaining =
            seconds
    }

    private func fireCompletion() {

        // Hook into haptics/audio/notification.
    }
}

// ============================================================
// TIME ZONE MANAGER
// ============================================================

@MainActor
final class TimeZoneManager:
    ObservableObject {

    @Published
    var selectedTimeZone =
        TimeZone.current

    var currentTime: Date {

        Date()
    }

    func time(
        zone: TimeZone
    ) -> DateComponents {

        var calendar =
            Calendar.current

        calendar.timeZone =
            zone

        return calendar.dateComponents(
            [
                .hour,
                .minute,
                .second,
                .day,
                .month,
                .year
            ],
            from:
                currentTime
        )
    }
}

// ============================================================
// CLOCK DASHBOARD
// ============================================================

struct ClockDashboard: View {

    @StateObject
    private var clock =
        ClockEngine()

    @StateObject
    private var world =
        WorldClockEngine()

    @StateObject
    private var stopwatch =
        StopwatchEngine()

    @StateObject
    private var countdown =
        CountdownTimerEngine()

    @State
    private var face:
        ClockFace = .system

    @State
    private var use24Hour = false

    var body: some View {

        NavigationStack {

            ScrollView {

                VStack(
                    spacing: 28
                ) {

                    // ----------------------------------------
                    // Main clock
                    // ----------------------------------------

                    Group {

                        switch face {

                        case .digital:

                            DigitalClockView(
                                clock: clock,
                                use24Hour:
                                    use24Hour
                            )

                        case .analog:

                            AnalogClockView(
                                clock: clock
                            )
                            .frame(
                                width: 280,
                                height: 280
                            )

                        case .minimal:

                            Text(
                                clock.formattedTime(
                                    use24Hour:
                                        use24Hour
                                )
                            )
                            .font(
                                .system(
                                    size: 64,
                                    weight: .ultraLight,
                                    design: .rounded
                                )
                            )
                            .monospacedDigit()

                        case .system:

                            DigitalClockView(
                                clock: clock,
                                use24Hour:
                                    use24Hour
                            )
                        }
                    }

                    Picker(
                        "Clock face",
                        selection: $face
                    ) {

                        ForEach(
                            ClockFace.allCases,
                            id: \.self
                        ) { face in

                            Text(
                                face.rawValue
                                    .capitalized
                            )
                            .tag(face)
                        }
                    }
                    .pickerStyle(
                        .segmented
                    )

                    Toggle(
                        "24-hour time",
                        isOn:
                            $use24Hour
                    )

                    Divider()

                    // ----------------------------------------
                    // World clocks
                    // ----------------------------------------

                    VStack(
                        alignment: .leading,
                        spacing: 12
                    ) {

                        Text(
                            "World Clock"
                        )
                        .font(
                            .title2.bold()
                        )

                        ForEach(
                            world.clocks,
                            id: \.identifier
                        ) { item in

                            HStack {

                                Text(
                                    item.city
                                )

                                Spacer()

                                Text(
                                    world.formattedTime(
                                        for: item
                                    )
                                )
                                .monospacedDigit()
                            }
                            .padding()
                            .background(
                                .regularMaterial,
                                in:
                                    RoundedRectangle(
                                        cornerRadius:
                                            14
                                    )
                            )
                        }
                    }

                    Divider()

                    // ----------------------------------------
                    // Stopwatch
                    // ----------------------------------------

                    VStack(
                        spacing: 14
                    ) {

                        Text(
                            "Stopwatch"
                        )
                        .font(
                            .title2.bold()
                        )

                        Text(
                            String(
                                format:
                                    "%02d:%02d.%02d",
                                Int(
                                    stopwatch.elapsed
                                ) / 60,
                                Int(
                                    stopwatch.elapsed
                                ) % 60,
                                Int(
                                    stopwatch.elapsed *
                                    100
                                ) % 100
                            )
                        )
                        .font(
                            .system(
                                size: 44,
                                weight: .light,
                                design: .monospaced
                            )
                        )

                        HStack {

                            Button(
                                stopwatch.running
                                ? "Pause"
                                : "Start"
                            ) {

                                if stopwatch.running {
                                    stopwatch.pause()
                                } else {
                                    stopwatch.start()
                                }
                            }
                            .buttonStyle(
                                .borderedProminent
                            )

                            Button("Reset") {

                                stopwatch.reset()
                            }
                        }
                    }

                    Divider()

                    // ----------------------------------------
                    // Timer
                    // ----------------------------------------

                    VStack(
                        spacing: 12
                    ) {

                        Text(
                            "Timer"
                        )
                        .font(
                            .title2.bold()
                        )

                        Text(
                            timerString
                        )
                        .font(
                            .system(
                                size: 44,
                                weight: .light,
                                design: .monospaced
                            )
                        )

                        HStack {

                            Button("5 min") {

                                countdown.reset(
                                    seconds:
                                        5 * 60
                                )
                            }

                            Button("10 min") {

                                countdown.reset(
                                    seconds:
                                        10 * 60
                                )
                            }

                            Button("Start") {

                                countdown.start()
                            }
                        }
                        .buttonStyle(
                            .bordered
                        )
                    }
                }
                .padding()
            }
            .navigationTitle(
                "Clock"
            )
        }
        .onAppear {

            clock.start()
        }
        .onDisappear {

            clock.stop()
        }
    }

    private var timerString: String {

        let total =
            Int(
                countdown.remaining
            )

        let minutes =
            total / 60

        let seconds =
            total % 60

        return String(
            format:
                "%02d:%02d",
            minutes,
            seconds
        )
    }
}

// ============================================================
// APP
// ============================================================

@main
struct AppleClockApp: App {

    var body: some Scene {

        WindowGroup {

            ClockDashboard()
        }
    }
}
```


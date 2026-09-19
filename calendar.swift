1. Calendar state
import SwiftUI
import Foundation

@MainActor
@Observable
final class AureomCalendarModel {

    var selectedDate = Date()
    var displayedMonth = Date()

    var isShowingDayView = false
    var searchText = ""

    var events: [AureomCalendarEvent] = []

    let calendar: Calendar

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        calendar.firstWeekday = 2

        self.calendar = calendar
    }

    func moveMonth(_ offset: Int) {

        guard let newDate =
                calendar.date(
                    byAdding: .month,
                    value: offset,
                    to: displayedMonth
                )
        else {
            return
        }

        displayedMonth = newDate
    }

    func jumpToToday() {
        let today = Date()

        selectedDate = today
        displayedMonth = today
    }
}

struct AureomCalendarEvent: Identifiable, Hashable {

    let id = UUID()

    var title: String
    var date: Date

    var duration: TimeInterval
    var location: String?
}
2. Build the month mathematically

Don't create a complicated collection of special-case calendar cells.

Generate the month once:

extension AureomCalendarModel {

    func daysInDisplayedMonth()
        -> [Date] {

        guard let range =
                calendar.range(
                    of: .day,
                    in: .month,
                    for: displayedMonth
                )
        else {
            return []
        }

        guard let start =
                calendar.date(
                    from: calendar.dateComponents(
                        [.year, .month],
                        from: displayedMonth
                    )
                )
        else {
            return []
        }

        return range.compactMap {
            calendar.date(
                byAdding: .day,
                value: $0 - 1,
                to: start
            )
        }
    }
}

Then calculate the weekday offset:

extension AureomCalendarModel {

    func leadingBlankDays() -> Int {

        guard let first =
                daysInDisplayedMonth().first
        else {
            return 0
        }

        let weekday =
            calendar.component(
                .weekday,
                from: first
            )

        return (
            weekday -
            calendar.firstWeekday +
            7
        ) % 7
    }
}

This makes the calendar layout deterministic and fast.

3. Smooth month transitions

Rather than instantly replacing January with February:

TabView {
    January()
    February()
}

I'd use a continuously draggable month surface.

struct AureomMonthView: View {

    @Bindable var model:
        AureomCalendarModel

    @State private var dragOffset: CGFloat = 0

    var body: some View {

        VStack(spacing: 0) {

            monthHeader

            weekdayHeader

            monthGrid
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(
                        minimumDistance: 12
                    )
                    .onChanged { value in

                        dragOffset =
                            value.translation.width
                    }
                    .onEnded { value in

                        let threshold: CGFloat = 80

                        if value.translation.width
                            < -threshold {

                            withAnimation(
                                .spring(
                                    response: 0.42,
                                    dampingFraction: 0.82
                                )
                            ) {
                                model.moveMonth(1)
                                dragOffset = 0
                            }

                        } else if value.translation.width
                            > threshold {

                            withAnimation(
                                .spring(
                                    response: 0.42,
                                    dampingFraction: 0.82
                                )
                            ) {
                                model.moveMonth(-1)
                                dragOffset = 0
                            }

                        } else {

                            withAnimation(
                                .spring(
                                    response: 0.35,
                                    dampingFraction: 0.9
                                )
                            ) {
                                dragOffset = 0
                            }
                        }
                    }
                )
        }
    }
}

This gives the calendar a much more physical feeling.

4. Beautiful day cells
private extension AureomMonthView {

    var monthGrid: some View {

        let days =
            model.daysInDisplayedMonth()

        let blanks =
            Array(
                repeating: Optional<Date>.none,
                count: model.leadingBlankDays()
            )

        let cells =
            blanks +
            days.map { Optional($0) }

        return LazyVGrid(
            columns:
                Array(
                    repeating:
                        GridItem(
                            .flexible(),
                            spacing: 4
                        ),
                    count: 7
                ),
            spacing: 7
        ) {

            ForEach(
                Array(cells.enumerated()),
                id: \.offset
            ) { _, date in

                if let date {

                    AureomDayCell(
                        date: date,
                        selected:
                            model.calendar.isDate(
                                date,
                                inSameDayAs:
                                    model.selectedDate
                            ),
                        hasEvent:
                            model.events.contains {
                                model.calendar.isDate(
                                    $0.date,
                                    inSameDayAs: date
                                )
                            }
                    )
                    .onTapGesture {

                        withAnimation(
                            .spring(
                                response: 0.3,
                                dampingFraction: 0.8
                            )
                        ) {

                            model.selectedDate =
                                date

                            model.isShowingDayView =
                                true
                        }
                    }

                } else {

                    Color.clear
                        .frame(height: 48)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

And:

struct AureomDayCell: View {

    let date: Date
    let selected: Bool
    let hasEvent: Bool

    @Environment(\.calendar)
    private var calendar

    var body: some View {

        VStack(spacing: 5) {

            Text(
                date.formatted(
                    .dateTime.day()
                )
            )
            .font(
                .system(
                    size: 16,
                    weight:
                        selected
                        ? .semibold
                        : .regular
                )
            )

            Circle()
                .fill(
                    hasEvent
                    ? Color.primary
                    : Color.clear
                )
                .frame(
                    width: 4,
                    height: 4
                )
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 48
        )
        .background {

            if selected {

                RoundedRectangle(
                    cornerRadius: 15,
                    style: .continuous
                )
                .fill(.primary)
                .matchedGeometryEffect(
                    id: "selectedDay",
                    in: namespace
                )
            }
        }
        .foregroundStyle(
            selected
            ? Color(.systemBackground)
            : .primary
        )
    }

    @Namespace
    private var namespace
}

I'd actually move the namespace to the parent calendar so the selected-day indicator can physically travel between cells rather than being recreated.

5. Make the calendar respond to vertical gestures

This is where it starts feeling substantially better than a conventional calendar.

MONTH
 ↓ swipe up

WEEK
 ↓ swipe up

DAY

and:

DAY
 ↑ swipe down

WEEK
 ↑ swipe down

MONTH

The calendar can therefore have three continuous states:

enum CalendarZoom {
    case month
    case week
    case day
}

Rather than navigating between separate screens, the content itself morphs.

6. The "today" button

I'd make this almost invisible until needed:

Button {
    model.jumpToToday()
} label: {

    Image(systemName: "calendar.circle.fill")
        .font(.system(size: 22))
}
.buttonStyle(.plain)

You can also add:

.keyboardShortcut(
    "t",
    modifiers: [.command]
)

so ⌘T jumps to today on iPad/Mac Catalyst.

7. Event display should be intelligent

Instead of putting text into every calendar cell:

18
Meeting
Doctor
Dinner
Gym

use density:

       18
       •
       ••

Then tapping the day expands the events into a beautiful bottom sheet.

.sheet(
    isPresented:
        $model.isShowingDayView
) {

    AureomDayAgenda(
        date: model.selectedDate,
        events: model.events
    )
    .presentationDetents([
        .medium,
        .large
    ])
    .presentationDragIndicator(
        .visible
    )
}

The result is much less visually noisy.

8. Make scrolling 120-Hz friendly

The important engineering principle is:

never perform expensive calendar calculations inside body.

Instead:

CalendarStore
     ↓
precomputed dates
     ↓
precomputed event index
     ↓
SwiftUI

I'd index events by day:

struct DayKey: Hashable {

    let year: Int
    let month: Int
    let day: Int
}

and:

var eventsByDay:
    [DayKey: [AureomCalendarEvent]]

Then checking whether a day has events becomes approximately:

eventsByDay[key] != nil

rather than scanning the entire event database for every calendar cell.

That becomes increasingly important when someone has thousands of calendar events.

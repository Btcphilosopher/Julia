Architecture
                 ALARM DATABASE
                       │
                       ▼
              ┌─────────────────┐
              │ Swift Scheduler │
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Julia Validator │
              │                 │
              │ conflicts       │
              │ recurrence      │
              │ next-fire       │
              │ reliability     │
              └────────┬────────┘
                       │
                       ▼
              VERIFIED ALARM PLAN
                       │
             ┌─────────┴─────────┐
             ▼                   ▼
      iOS notification      local alarm DB
             │                   │
             └─────────┬─────────┘
                       ▼
                  ALARM FIRES
Swift alarm engine
import Foundation
import UserNotifications
import UIKit

struct AureomAlarm: Codable, Identifiable, Sendable {
    let id: UUID
    var hour: Int
    var minute: Int
    var enabled: Bool

    var weekdays: Set<Int>

    // 1 = Sunday
    // 2 = Monday
    // ...
    // 7 = Saturday

    var title: String
    var soundName: String
}

actor AureomAlarmStore {

    private var alarms: [UUID: AureomAlarm] = [:]

    func save(_ alarm: AureomAlarm) {
        alarms[alarm.id] = alarm
    }

    func remove(_ id: UUID) {
        alarms.removeValue(forKey: id)
    }

    func all() -> [AureomAlarm] {
        Array(alarms.values)
    }

    func alarm(_ id: UUID) -> AureomAlarm? {
        alarms[id]
    }
}
Permission and notification manager
final class AureomAlarmManager {

    static let shared = AureomAlarmManager()

    private let center =
        UNUserNotificationCenter.current()

    private init() {}

    func requestPermission() async throws -> Bool {

        try await center.requestAuthorization(
            options: [
                .alert,
                .sound,
                .badge
            ]
        )
    }

    func authorizationStatus() async
        -> UNAuthorizationStatus {

        let settings =
            await center.notificationSettings()

        return settings.authorizationStatus
    }
}
Scheduling
extension AureomAlarmManager {

    func schedule(
        _ alarm: AureomAlarm
    ) async throws {

        guard alarm.enabled else {
            return
        }

        let identifier =
            "aureom.alarm.\(alarm.id.uuidString)"

        // Remove an existing schedule first.
        center.removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )

        for weekday in alarm.weekdays {

            var components = DateComponents()

            components.calendar = Calendar.current
            components.weekday = weekday
            components.hour = alarm.hour
            components.minute = alarm.minute

            let trigger =
                UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: true
                )

            let content =
                UNMutableNotificationContent()

            content.title = alarm.title
            content.body = "Alarm"
            content.sound =
                UNNotificationSound(
                    named: UNNotificationSoundName(
                        alarm.soundName
                    )
                )

            let request =
                UNNotificationRequest(
                    identifier:
                        "\(identifier).\(weekday)",
                    content: content,
                    trigger: trigger
                )

            try await center.add(request)
        }
    }
}
The verification layer

This is where I'd make the system considerably more robust.

After scheduling an alarm, don't simply assume iOS accepted it.

Ask iOS what is actually pending:

extension AureomAlarmManager {

    func pendingRequests()
        async -> [UNNotificationRequest] {

        await center.pendingNotificationRequests()
    }

    func verify(
        alarm: AureomAlarm
    ) async -> Bool {

        let requests =
            await pendingRequests()

        let prefix =
            "aureom.alarm.\(alarm.id.uuidString)"

        let matches =
            requests.filter {
                $0.identifier.hasPrefix(prefix)
            }

        return !matches.isEmpty
    }
}

Then:

func verifyAndRepair(
    alarm: AureomAlarm
) async {

    let manager =
        AureomAlarmManager.shared

    let valid =
        await manager.verify(
            alarm: alarm
        )

    if !valid {

        do {
            try await manager.schedule(alarm)
        } catch {
            print(
                "Alarm repair failed:",
                error
            )
        }
    }
}

That gives you:

CREATE
  ↓
SCHEDULE
  ↓
ASK iOS
  ↓
IS IT PENDING?
  ├── YES → verified
  │
  └── NO → reschedule
Julia reliability engine

Julia can handle the mathematical side.

module AureomAlarmReliability

export Alarm, next_alarm, conflicts, reliability_score

struct Alarm
    hour::Int
    minute::Int
    weekdays::Vector{Int}
end

function minutes_from_midnight(a::Alarm)
    return a.hour * 60 + a.minute
end

function conflicts(a::Alarm, b::Alarm; tolerance=2)

    if isempty(intersect(
        Set(a.weekdays),
        Set(b.weekdays)
    ))
        return false
    end

    return abs(
        minutes_from_midnight(a) -
        minutes_from_midnight(b)
    ) <= tolerance
end

function reliability_score(
    notification_authorized::Bool,
    alarm_enabled::Bool,
    scheduled_count::Int,
    expected_count::Int
)

    score = 1.0

    if !notification_authorized
        score -= 0.6
    end

    if !alarm_enabled
        score -= 0.4
    end

    if expected_count > 0

        coverage =
            scheduled_count /
            expected_count

        score *= coverage
    end

    return clamp(score, 0.0, 1.0)
end

end

You could then expose the Julia model to Swift through a native bridge or, preferably, use Julia offline during development/calibration and keep the actual alarm-critical runtime entirely Swift.

I'd add a "proof of alarm" state

The app can maintain something like:

enum AlarmIntegrity: String {
    case verified
    case needsRepair
    case permissionMissing
    case disabled
    case unknown
}

struct AlarmHealth {
    let integrity: AlarmIntegrity
    let pendingNotifications: Int
    let nextFireDate: Date?
}


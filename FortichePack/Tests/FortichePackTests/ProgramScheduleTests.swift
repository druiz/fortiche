import Foundation
import Testing
@testable import FortichePack

@MainActor
@Suite struct ProgramScheduleTests {
    func makeTemplate(days: [String]) -> WorkoutTemplate {
        let template = WorkoutTemplate(name: "PPL")
        template.days = days.enumerated().map { TemplateDay(name: $1, order: $0) }
        return template
    }

    func makeLog(template: WorkoutTemplate, dayName: String, daysAgo: Int) -> WorkoutLog {
        let log = WorkoutLog(
            title: dayName,
            startedAt: Date(timeIntervalSinceNow: TimeInterval(-daysAgo * 86400)),
            host: .phone
        )
        log.templateUUID = template.uuid
        log.dayUUID = template.orderedDays.first { $0.name == dayName }?.uuid
        return log
    }

    @Test func noHistorySuggestsFirstDay() {
        let template = makeTemplate(days: ["Push", "Pull", "Legs"])
        #expect(ProgramSchedule.nextDay(in: template, logs: [])?.name == "Push")
    }

    @Test func suggestsDayAfterLastLogged() {
        let template = makeTemplate(days: ["Push", "Pull", "Legs"])
        let logs = [makeLog(template: template, dayName: "Push", daysAgo: 1)]
        #expect(ProgramSchedule.nextDay(in: template, logs: logs)?.name == "Pull")
    }

    @Test func wrapsAroundAfterLastDay() {
        let template = makeTemplate(days: ["Push", "Pull", "Legs"])
        let logs = [
            makeLog(template: template, dayName: "Pull", daysAgo: 3),
            makeLog(template: template, dayName: "Legs", daysAgo: 1),
        ]
        #expect(ProgramSchedule.nextDay(in: template, logs: logs)?.name == "Push")
    }

    @Test func usesMostRecentLogNotOrderOfArray() {
        let template = makeTemplate(days: ["Push", "Pull", "Legs"])
        let logs = [
            makeLog(template: template, dayName: "Legs", daysAgo: 1),
            makeLog(template: template, dayName: "Push", daysAgo: 5),
        ]
        #expect(ProgramSchedule.nextDay(in: template, logs: logs)?.name == "Push")
    }

    @Test func deletedDayFallsBackToFirst() {
        let template = makeTemplate(days: ["Push", "Pull"])
        let log = makeLog(template: template, dayName: "Push", daysAgo: 1)
        log.dayUUID = UUID() // day no longer exists
        #expect(ProgramSchedule.nextDay(in: template, logs: [log])?.name == "Push")
    }

    @Test func activeTemplateIsMostRecentlyTrained() {
        let a = makeTemplate(days: ["A1"])
        let b = makeTemplate(days: ["B1"])
        let logs = [
            makeLog(template: a, dayName: "A1", daysAgo: 5),
            makeLog(template: b, dayName: "B1", daysAgo: 1),
        ]
        #expect(ProgramSchedule.activeTemplate(in: [a, b], logs: logs)?.uuid == b.uuid)
        #expect(ProgramSchedule.activeTemplate(in: [a, b], logs: [])?.uuid == a.uuid)
    }
}

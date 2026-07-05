import Foundation

/// "What should I do next?" — suggestion logic shared by the phone list,
/// the watch list, and (later) widgets/Siri suggestions.
public enum ProgramSchedule {
    /// The next day to train in a template: the day after the most recently
    /// logged day (by template order, wrapping), or the first day when the
    /// template has no history.
    public static func nextDay(in template: WorkoutTemplate, logs: [WorkoutLog]) -> TemplateDay? {
        let days = template.orderedDays
        guard !days.isEmpty else { return nil }

        let lastLoggedDayUUID = logs
            .filter { $0.templateUUID == template.uuid && $0.dayUUID != nil }
            .max { $0.startedAt < $1.startedAt }?
            .dayUUID

        guard let lastLoggedDayUUID,
              let lastIndex = days.firstIndex(where: { $0.uuid == lastLoggedDayUUID })
        else { return days.first }

        // Wrap back to day 1 after the program's last day.
        return days[(lastIndex + 1) % days.count]
    }

    /// The template the user is currently "on": the one trained most recently,
    /// else the first available.
    public static func activeTemplate(in templates: [WorkoutTemplate], logs: [WorkoutLog]) -> WorkoutTemplate? {
        let templateUUIDs = Set(templates.map(\.uuid))
        let mostRecent = logs
            .filter { $0.templateUUID.map(templateUUIDs.contains) == true }
            .max { $0.startedAt < $1.startedAt }
        if let uuid = mostRecent?.templateUUID,
           let template = templates.first(where: { $0.uuid == uuid }) {
            return template
        }
        return templates.first
    }
}

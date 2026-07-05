import Foundation

/// Read-only analytics over workout history. Pure functions so they're testable
/// and usable from any target.
public enum WorkoutStats {
    /// Epley estimated 1-rep max: weight × (1 + reps/30).
    public static func estimatedOneRepMax(weightKg: Double, reps: Int) -> Double {
        guard reps > 0 else { return 0 }
        guard reps > 1 else { return weightKg }
        return weightKg * (1 + Double(reps) / 30)
    }

    public struct ExerciseBest: Sendable, Equatable {
        public var slugOrName: String
        public var bestEstimatedOneRepMaxKg: Double
        public var bestSetWeightKg: Double
        public var bestSetReps: Int
        public var date: Date
    }

    /// Best e1RM per exercise across logs, keyed by librarySlug when present
    /// else lowercased name.
    public static func personalRecords(from logs: [WorkoutLog]) -> [String: ExerciseBest] {
        var records: [String: ExerciseBest] = [:]
        for log in logs {
            for exercise in log.orderedExercises {
                let key = exercise.librarySlug ?? exercise.name.lowercased()
                for set in exercise.orderedSets where set.completedAt != nil {
                    guard let weight = set.weightKg, weight > 0, set.reps > 0 else { continue }
                    let e1rm = estimatedOneRepMax(weightKg: weight, reps: set.reps)
                    if e1rm > (records[key]?.bestEstimatedOneRepMaxKg ?? 0) {
                        records[key] = ExerciseBest(
                            slugOrName: exercise.name,
                            bestEstimatedOneRepMaxKg: e1rm,
                            bestSetWeightKg: weight,
                            bestSetReps: set.reps,
                            date: set.completedAt ?? log.startedAt
                        )
                    }
                }
            }
        }
        return records
    }

    public struct DailyVolume: Sendable, Equatable, Identifiable {
        public var id: Date { day }
        public var day: Date
        public var volumeKg: Double
    }

    /// Total volume (Σ reps × weight) per calendar day, ascending.
    public static func dailyVolume(from logs: [WorkoutLog], calendar: Calendar = .current) -> [DailyVolume] {
        var byDay: [Date: Double] = [:]
        for log in logs {
            let day = calendar.startOfDay(for: log.startedAt)
            let volume = log.orderedExercises
                .flatMap(\.orderedSets)
                .reduce(0.0) { $0 + Double($1.reps) * ($1.weightKg ?? 0) }
            byDay[day, default: 0] += volume
        }
        return byDay.map { DailyVolume(day: $0.key, volumeKg: $0.value) }
            .sorted { $0.day < $1.day }
    }

    /// Most recent completed performance of an exercise before `date` — the
    /// "previous performance ghost" shown while lifting.
    public static func lastPerformance(
        ofSlug slug: String?,
        name: String,
        before date: Date,
        in logs: [WorkoutLog]
    ) -> (reps: Int, weightKg: Double?, date: Date)? {
        let key = slug ?? name.lowercased()
        let candidates = logs
            .filter { $0.startedAt < date }
            .sorted { $0.startedAt > $1.startedAt }
        for log in candidates {
            for exercise in log.orderedExercises {
                let exerciseKey = exercise.librarySlug ?? exercise.name.lowercased()
                guard exerciseKey == key else { continue }
                if let topSet = exercise.orderedSets
                    .filter({ $0.completedAt != nil })
                    .max(by: { ($0.weightKg ?? 0) < ($1.weightKg ?? 0) }) {
                    return (topSet.reps, topSet.weightKg, log.startedAt)
                }
            }
        }
        return nil
    }
}

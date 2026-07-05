import Foundation
import Testing
@testable import FortichePack

@MainActor
@Suite struct StatsTests {
    func makeLog(daysAgo: Int, exercise: String, slug: String?, reps: Int, weight: Double) -> WorkoutLog {
        let log = WorkoutLog(title: "T", startedAt: Date(timeIntervalSinceNow: TimeInterval(-daysAgo * 86400)), host: .phone)
        let ex = LoggedExercise(name: exercise, order: 0, librarySlug: slug)
        let set = LoggedSet(order: 0, reps: reps, weightKg: weight)
        set.completedAt = log.startedAt
        ex.sets = [set]
        log.exercises = [ex]
        return log
    }

    @Test func epleyOneRepMax() {
        #expect(WorkoutStats.estimatedOneRepMax(weightKg: 100, reps: 1) == 100)
        #expect(abs(WorkoutStats.estimatedOneRepMax(weightKg: 100, reps: 5) - 116.667) < 0.01)
        #expect(WorkoutStats.estimatedOneRepMax(weightKg: 100, reps: 0) == 0)
    }

    @Test func personalRecordsTakeBestE1RM() {
        let logs = [
            makeLog(daysAgo: 10, exercise: "Squat", slug: "Barbell_Squat", reps: 5, weight: 100), // e1rm ~116.7
            makeLog(daysAgo: 3, exercise: "Squat", slug: "Barbell_Squat", reps: 3, weight: 110),  // e1rm ~121
        ]
        let records = WorkoutStats.personalRecords(from: logs)
        let squat = records["Barbell_Squat"]
        #expect(squat?.bestSetWeightKg == 110)
        #expect(squat?.bestSetReps == 3)
    }

    @Test func lastPerformanceFindsMostRecentPriorSession() {
        let logs = [
            makeLog(daysAgo: 10, exercise: "Bench", slug: nil, reps: 5, weight: 80),
            makeLog(daysAgo: 3, exercise: "Bench", slug: nil, reps: 5, weight: 82.5),
        ]
        let result = WorkoutStats.lastPerformance(ofSlug: nil, name: "Bench", before: .now, in: logs)
        #expect(result?.weightKg == 82.5)
    }

    @Test func dailyVolumeAggregatesPerDay() {
        let logs = [
            makeLog(daysAgo: 1, exercise: "Squat", slug: nil, reps: 5, weight: 100), // 500
            makeLog(daysAgo: 1, exercise: "Bench", slug: nil, reps: 5, weight: 80),  // 400 same day
        ]
        let volume = WorkoutStats.dailyVolume(from: logs)
        #expect(volume.count == 1)
        #expect(volume.first?.volumeKg == 900)
    }
}

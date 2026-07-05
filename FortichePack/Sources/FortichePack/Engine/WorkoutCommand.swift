import Foundation

/// Every mutation of an active workout is a command. Commands are applied by
/// the authoritative engine (watch when a watch session runs, phone otherwise)
/// and replicated to the peer as sequenced envelopes.
public enum WorkoutCommand: Codable, Sendable, Equatable {
    case completeSet(exercise: Int, set: Int, reps: Int, weightKg: Double?)
    case uncompleteSet(exercise: Int, set: Int)
    case adjustWeight(exercise: Int, set: Int, weightKg: Double?)
    case adjustReps(exercise: Int, set: Int, repsMin: Int, repsMax: Int)
    case addSet(exercise: Int)
    case removeLastSet(exercise: Int)
    case skipExercise(Int)
    case unskipExercise(Int)
    case selectExercise(Int)
    case skipRest
    case adjustRest(deltaSeconds: Int)
    case pause
    case resume
    case end
}

public struct CommandEnvelope: Codable, Sendable, Equatable {
    public var origin: WorkoutHost
    /// Monotonic per-origin sequence number.
    public var seq: Int
    public var command: WorkoutCommand
    public var sentAt: Date

    public init(origin: WorkoutHost, seq: Int, command: WorkoutCommand, sentAt: Date = .now) {
        self.origin = origin
        self.seq = seq
        self.command = command
        self.sentAt = sentAt
    }
}

/// Wire protocol between the two devices during an active workout.
/// Carried over `sendToRemoteWorkoutSession` in production and over
/// WatchConnectivity in the simulator debug transport.
public enum SyncMessage: Codable, Sendable, Equatable {
    /// Peer → authority: apply this command.
    /// Authority → peer: (not used; the authority replies with snapshots).
    case command(CommandEnvelope)
    /// Authority → peer: full state after applying commands.
    case snapshot(WorkoutState)
    /// Peer → authority: please resend the full state (reconnect/recovery).
    case requestSnapshot

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncMessage {
        try JSONDecoder().decode(SyncMessage.self, from: data)
    }
}

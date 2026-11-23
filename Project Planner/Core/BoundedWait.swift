//
//  BoundedWait.swift
//  Project Planner
//
//  A save never sticks on "Saving…" (owner decision 17 Nov, web "A save never sticks on Saving…"; issue #16 on iOS):
//  a Storage upload or Firestore write that does not answer within a fixed time is given up on with a real message.
//
//  Unlike a task-group timeout, this returns as soon as the time is up even when the work ignores cancellation (a
//  Firestore write waits for the server and never checks for cancellation; a task group would wait for it). The work
//  is still cancelled, so a Storage upload that listens for cancellation (`uploadQualificationDocument`) stops.
//

import Foundation
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

enum BoundedWait {
    /// The work did not answer in time.
    nonisolated struct TimedOut: LocalizedError, Equatable {
        let seconds: Double
        var errorDescription: String? {
            "No answer from the server after \(Int(seconds.rounded())) seconds. Check your connection and try again."
        }
    }

    /// One wait: resumes the caller exactly once — with the work's answer, `TimedOut`, or `CancellationError` when
    /// the caller is cancelled — and then stops the other task.
    nonisolated private final class Race<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var finished = false
        /// The answer when it came before `start` (the caller cancelled at once).
        private var early: Result<T, Error>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        func start(_ continuation: CheckedContinuation<T, Error>, work: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            if finished {
                lock.unlock()
                work.cancel()
                timer.cancel()
                continuation.resume(with: early ?? .failure(CancellationError()))
                return
            }
            self.continuation = continuation
            self.work = work
            self.timer = timer
            lock.unlock()
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            early = result
            let continuation = self.continuation
            let work = self.work
            let timer = self.timer
            self.continuation = nil
            lock.unlock()
            work?.cancel()
            timer?.cancel()
            continuation?.resume(with: result)
        }
    }

    /// `operation`, or `TimedOut` after `seconds` (the work is cancelled then and its late answer ignored). When the
    /// work answers first the timer is cancelled; when the caller is cancelled both are and `CancellationError` is
    /// thrown at once.
    static func run<T>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let work = Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    } catch {
                        return
                    }
                    race.finish(.failure(TimedOut(seconds: seconds)))
                }
                race.start(continuation, work: work, timer: timer)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

#if canImport(FirebaseStorage)
/// Holds a Storage upload so a cancelled save can stop it (`FirebaseBackend.uploadQualificationDocument`).
nonisolated final class QualificationUploadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var _task: StorageUploadTask?

    var task: StorageUploadTask? {
        get { lock.lock(); defer { lock.unlock() }; return _task }
        set {
            lock.lock()
            _task = newValue
            let stop = cancelled
            lock.unlock()
            if stop { newValue?.cancel() }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = _task
        lock.unlock()
        current?.cancel()
    }
}
#endif

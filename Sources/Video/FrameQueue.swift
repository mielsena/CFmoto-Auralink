// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from the `LinkedBlockingDeque<ByteArray>(8)` in VideoPipeline.kt's drain loop: a small
// bounded queue between the encoder's output and the bike's lock-step `REQ_RV_DATA_NEXT` pull.
// Same "drop oldest, never block the producer" policy — the encoder must never stall waiting for
// queue space, since that would stall the fixed-rate feed timer in VideoPipeline.swift.
//
// Single-consumer by design: the bike protocol only ever has one outstanding `REQ_RV_DATA_NEXT`
// at a time (docs/01-PROTOCOL-REFERENCE.md §4, "lock-step"), so `poll(timeout:)` assumes at most
// one caller waiting at once. A second concurrent waiter would silently replace the first's
// continuation — not a concern for this protocol's actual call pattern.

import Foundation

actor FrameQueue {
    private var buffer: [Data] = []
    private let capacity: Int
    /// `token` disambiguates a stale timeout firing after a *newer* `poll` call has already
    /// registered its own waiter — see `expireWaiter(token:)`. Plain `CheckedContinuation` isn't
    /// `Equatable`, so identity can't be checked directly; a monotonic counter is the standard
    /// workaround.
    private var waiter: (token: UInt64, continuation: CheckedContinuation<Data?, Never>)?
    private var nextToken: UInt64 = 0
    private(set) var droppedFrames = 0

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    /// Appends a frame, dropping the oldest if full. Never blocks — safe to call from the encoder's
    /// output callback on any thread via `Task { await queue.offer(frame) }`.
    func offer(_ frame: Data) {
        if buffer.count >= capacity {
            buffer.removeFirst()
            droppedFrames += 1
        }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: frame)
            return
        }
        buffer.append(frame)
    }

    /// Waits up to `timeout` for the next frame; returns `nil` on timeout (mirrors Kotlin
    /// `pollFirst(timeoutMs, TimeUnit.MILLISECONDS)`).
    ///
    /// Deliberately NOT built on `withTaskGroup` racing a continuation against `Task.sleep`:
    /// cancelling a task does not resume a bare `withCheckedContinuation` inside it, so the losing
    /// child task would hang forever and the group could never return (caught by
    /// `FrameQueueTests.pollTimesOutWhenEmpty` hanging the whole test run). Instead, a plain timer
    /// task races against `offer`/`clear` to resume the SAME continuation — mutual exclusion is
    /// free here because actor methods never interleave with each other.
    func poll(timeout: Duration) async -> Data? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        nextToken += 1
        let token = nextToken
        return await withCheckedContinuation { continuation in
            waiter = (token, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireWaiter(token: token)
            }
        }
    }

    /// Resolves `waiter` with `nil` if it's still the one registered for `token` — a no-op if
    /// `offer`/`clear` already resumed it, or if a later `poll` call replaced it first.
    private func expireWaiter(token: UInt64) {
        guard let waiter, waiter.token == token else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }

    func clear() {
        buffer.removeAll()
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: nil)
        }
    }
}

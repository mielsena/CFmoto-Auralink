// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.

import Testing
import Foundation
@testable import AuraLink

struct FrameQueueTests {
    @Test func pollReturnsFrameAlreadyInQueue() async {
        let queue = FrameQueue(capacity: 4)
        await queue.offer(Data([1, 2, 3]))
        let result = await queue.poll(timeout: .milliseconds(500))
        #expect(result == Data([1, 2, 3]))
    }

    @Test func pollTimesOutWhenEmpty() async {
        let queue = FrameQueue(capacity: 4)
        let start = ContinuousClock.now
        let result = await queue.poll(timeout: .milliseconds(100))
        #expect(result == nil)
        #expect(ContinuousClock.now - start >= .milliseconds(90))
    }

    @Test func pollWakesUpAsSoonAsFrameArrives() async {
        let queue = FrameQueue(capacity: 4)
        let task = Task {
            await queue.poll(timeout: .seconds(5))
        }
        try? await Task.sleep(for: .milliseconds(50))
        await queue.offer(Data([9, 9]))
        let result = await task.value
        #expect(result == Data([9, 9]))
    }

    @Test func offerDropsOldestWhenFull() async {
        let queue = FrameQueue(capacity: 2)
        await queue.offer(Data([1]))
        await queue.offer(Data([2]))
        await queue.offer(Data([3])) // queue full — should drop [1]
        let first = await queue.poll(timeout: .milliseconds(100))
        let second = await queue.poll(timeout: .milliseconds(100))
        #expect(first == Data([2]))
        #expect(second == Data([3]))
        #expect(await queue.droppedFrames == 1)
    }

    @Test func clearEmptiesQueueAndWakesWaiter() async {
        let queue = FrameQueue(capacity: 4)
        await queue.offer(Data([1]))
        await queue.clear()
        let result = await queue.poll(timeout: .milliseconds(100))
        #expect(result == nil)
    }

    @Test func clearResumesAWaitingPollWithNil() async {
        let queue = FrameQueue(capacity: 4)
        let task = Task {
            await queue.poll(timeout: .seconds(5))
        }
        try? await Task.sleep(for: .milliseconds(50))
        await queue.clear()
        let result = await task.value
        #expect(result == nil)
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Generic Network.framework transport for the PXC sockets. Android's `EasyConnProber.kt` uses
// blocking `ServerSocket`/`Socket` (java.net); the iOS equivalent is `NWListener`/`NWConnection`
// (Network.framework), wrapped here with async/await so the protocol-dispatch code in
// EasyConnProber.swift reads top-to-bottom like the Kotlin original's blocking I/O, instead of
// nesting completion handlers. This file is intentionally protocol-agnostic — no PxcFrame/ReqBase
// knowledge here, just bytes in/out.

import Foundation
import Network
import os

/// A one-shot latch for continuation callbacks that can fire more than once (e.g.
/// `NWConnection.stateUpdateHandler` reporting `.waiting` before `.ready`/`.failed`). Backed by
/// `OSAllocatedUnfairLock` (iOS 16+) so it's safely `Sendable` under strict concurrency checking —
/// a bare captured `var Bool` triggers a Swift 6 data-race error when mutated from a
/// `stateUpdateHandler` closure, even though Network.framework only ever invokes it serially on
/// the queue passed to `start(queue:)`.
final class ResumeOnce: @unchecked Sendable {
    private let fired = OSAllocatedUnfairLock(initialState: false)

    /// Returns `true` exactly once — the first caller wins, every subsequent call returns `false`.
    func tryFire() -> Bool {
        fired.withLock { alreadyFired in
            guard !alreadyFired else { return false }
            alreadyFired = true
            return true
        }
    }
}

enum BikeSocketError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case cancelled
    case closed

    var description: String {
        switch self {
        case .invalidPort(let p): return "BikeSocket: invalid port \(p)"
        case .cancelled: return "BikeSocket: connection cancelled"
        case .closed: return "BikeSocket: connection closed by peer"
        }
    }
}

/// One TCP connection to/from the bike — either an accepted inbound socket (from
/// `PxcTcpServer`) or the single outbound probe socket to `:10930`. Wraps `NWConnection` with
/// async `start()`/`send(_:)`/`receiveExactly(_:)`, matching the blocking read/write shape the
/// protocol layer (`PxcFrame`/`ReqBaseFrame`) was designed against.
///
/// `@unchecked Sendable`: `NWConnection` and `DispatchQueue` are both safe to share across
/// concurrency domains (Apple's own guidance — Network.framework types are thread-safe when all
/// calls are funneled through the queue passed to `start(queue:)`, which is exactly what every
/// method below does), but neither is statically `Sendable`.
final class BikeSocket: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private(set) var remoteDescription: String = "?"

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Builds (but does not start) an outbound connection, pinned to Wi-Fi so iOS never tries to
    /// route the bike's no-internet AP traffic over cellular — see
    /// docs/04-CONTINUE-HANDOFF.md's Apple-console gotcha #3.
    static func outbound(host: String, port: UInt16, queue: DispatchQueue) throws -> BikeSocket {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw BikeSocketError.invalidPort(port) }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        params.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        return BikeSocket(connection: connection, queue: queue)
    }

    /// Starts the connection (dials out for an outbound socket; completes the handshake for an
    /// inbound accepted one — `NWListener`-vended connections still need `start(queue:)` called)
    /// and waits for `.ready`. The state handler only ever resumes once: `NWConnection` can report
    /// `.waiting` repeatedly before `.ready`/`.failed`, and the continuation would trap on a second
    /// resume if we didn't guard it.
    func start() async throws {
        remoteDescription = "\(connection.endpoint)"
        let resumeGuard = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumeGuard.tryFire() { continuation.resume() }
                case .failed(let error):
                    if resumeGuard.tryFire() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumeGuard.tryFire() { continuation.resume(throwing: BikeSocketError.cancelled) }
                default:
                    break // .setup / .preparing / .waiting — keep waiting.
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Reads exactly `count` bytes, accumulating across multiple TCP segments if needed — the
    /// async equivalent of the Kotlin `PxcFrame.readFully`.
    func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = Data(capacity: count)
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk = try await receiveChunk(maximum: remaining)
            guard !chunk.isEmpty else { throw BikeSocketError.closed }
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveChunk(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data()) // peer closed — caller sees an empty chunk.
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func cancel() {
        connection.cancel()
    }
}

enum PxcTcpServerError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case listenFailed(String)

    var description: String {
        switch self {
        case .invalidPort(let p): return "PxcTcpServer: invalid port \(p)"
        case .listenFailed(let s): return "PxcTcpServer: \(s)"
        }
    }
}

/// One `NWListener` bound to a single port. `EasyConnProber` opens three of these (10920/10921/
/// 10922) — see docs/01-PROTOCOL-REFERENCE.md §2. When `localAddress` is known (the phone's
/// resolved IP on the bike's Wi-Fi), the listener is pinned to it via `requiredLocalEndpoint` so it
/// can't collide with/leak onto another interface; when unknown, `requiredInterfaceType = .wifi`
/// alone still keeps it off cellular.
final class PxcTcpServer: @unchecked Sendable {
    let port: UInt16
    private let queue: DispatchQueue
    private var listener: NWListener?
    private let onAccept: (BikeSocket) -> Void

    init(port: UInt16, onAccept: @escaping (BikeSocket) -> Void) {
        self.port = port
        self.onAccept = onAccept
        self.queue = DispatchQueue(label: "auralink.pxc-listener.\(port)")
    }

    func start(localAddress: String?) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw PxcTcpServerError.invalidPort(port) }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        params.prohibitedInterfaceTypes = [.cellular]
        params.allowLocalEndpointReuse = true
        if let localAddress {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(localAddress), port: nwPort)
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw PxcTcpServerError.listenFailed("bind :\(port) failed: \(error)")
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.onAccept(BikeSocket(connection: connection, queue: self.queue))
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var isOpen: Bool { listener != nil }
}

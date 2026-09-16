// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from LogBus.kt. Process-wide log sink so every stage — protocol handshake, networking,
// video pipeline, UI — funnels into one timestamped buffer that the on-screen log view observes
// and the Share Log action exports. Miel cannot read a stack trace, so this buffer (not Xcode
// console output) is the entire diagnostic surface for a bike test session. Prefix every line with
// a stage tag (`[PXC]`, `[VIDEO]`, `[:10922]`, …) per the project convention.

import Foundation
import OSLog

/// A single already-timestamped log line, retained in-memory for the on-screen log view and Share
/// Log export.
struct LogLine: Identifiable, Sendable {
    let id: UInt64
    let timestamp: Date
    let text: String
}

/// Central log sink. Safe to call from any thread/Task — internally serialized by an actor.
actor LogBus {
    static let shared = LogBus()

    private let osLog = Logger(subsystem: "com.amielsena.auralink", category: "AuraLink")
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var lines: [LogLine] = []
    private var nextId: UInt64 = 0
    private var throttleUntil: [String: Date] = [:]

    /// Hard cap on retained lines so a long ride doesn't grow this unbounded. Generous enough to
    /// cover a multi-hour ride's worth of heartbeats/frames while staying well under a few MB.
    private let maxLines = 20_000

    /// Subscribers (typically one: the log view) notified on every new line, on the actor's executor.
    private var listeners: [UUID: (LogLine) -> Void] = [:]

    private init() {}

    @discardableResult
    func addListener(_ listener: @escaping (LogLine) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    func log(_ message: String) {
        let redacted = LogRedactor.redact(message)
        let line = LogLine(id: nextId, timestamp: Date(), text: "\(timeFormatter.string(from: Date()))  \(redacted)")
        nextId += 1
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines / 2)
        }
        osLog.info("\(redacted, privacy: .public)")
        for listener in listeners.values { listener(line) }
    }

    /// Same as `log`, but drops repeats for `key` until `minInterval` elapses. Use for hot paths
    /// (touch MOVE, per-frame ticks) so the buffer isn't flooded.
    func logThrottled(_ key: String, _ message: String, minInterval: TimeInterval = 0.5) {
        let now = Date()
        if let until = throttleUntil[key], now < until { return }
        throttleUntil[key] = now.addingTimeInterval(minInterval)
        if throttleUntil.count > 64 {
            throttleUntil = throttleUntil.filter { $0.value >= now }
        }
        log(message)
    }

    func snapshot() -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    func clear() {
        lines.removeAll()
    }

    func recentLines(_ count: Int) -> [LogLine] {
        Array(lines.suffix(count))
    }

    func logSessionBanner() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("[BUILD] AuraLink \(version) (\(build))")
        log("[BUILD] --- session start ---")
    }
}

/// Strips Wi-Fi passwords / RSA key material from log lines before they hit the buffer or Share
/// Log export, mirroring LogRedactor.kt. Errs on the side of over-redacting rather than leaking a
/// bike's Wi-Fi password in a support log.
enum LogRedactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"("pwd"\s*:\s*")[^"]*(")"#, "$1<redacted>$2"),
            (#"("password"\s*:\s*")[^"]*(")"#, "$1<redacted>$2"),
            (#"(pwd=)[^&\s"]+"#, "$1<redacted>"),
            (#"("pubkey"\s*:\s*")[^"]*(")"#, "$1<redacted>$2"),
            (#"("encryptedHUID"\s*:\s*")[^"]*(")"#, "$1<redacted>$2"),
        ]
        return specs.compactMap { pattern, template in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (re, template)
        }
    }()

    static func redact(_ input: String) -> String {
        var out = input
        for (re, template) in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }
}

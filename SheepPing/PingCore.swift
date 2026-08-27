import Foundation
import SwiftUI
import Combine

// MARK: - PingResult  (Sendable: crosses actor boundaries)
//
// `nonisolated` is load-bearing: the project sets SWIFT_DEFAULT_ACTOR_ISOLATION
// to MainActor, so without it this value — built on a background thread by the
// ping stream and read again off the main actor by tests — inherits MainActor
// isolation and its own producer cannot touch its properties.
nonisolated struct PingResult: Sendable {
    let isSuccess: Bool
    let resolvedIP: String
    let latency: Double?
    let message: String
}

// MARK: - Sendable plumbing for the ping subprocess
//
// Process and Pipe are not Sendable, and `Process.terminationHandler` is a
// `@Sendable` closure, so under Swift 6 nothing that touches them may be
// captured directly. ProcessBox owns the Process and hands out only Sendable
// operations; whatever reads the pipe (see PingLineReader) deliberately holds
// no reference back to the Process, so the handler cannot form a retain cycle.

private nonisolated final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var didLaunch = false
    private var killRequested = false

    init(executable: String, arguments: [String], pipe: Pipe) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func setTerminationHandler(_ handler: @escaping @Sendable (Process) -> Void) {
        process.terminationHandler = handler
    }

    func run() throws {
        lock.lock(); defer { lock.unlock() }
        try process.run()
        didLaunch = true
        // A sub-second deadline can fire before run() gets here. Honour the kill
        // now instead of leaving an orphan ping running out its own -t.
        if killRequested { process.terminate() }
    }

    /// Safe before launch, after exit, and from another thread.
    func terminate() {
        lock.lock(); defer { lock.unlock() }
        killRequested = true
        guard didLaunch, process.isRunning else { return }
        process.terminate()
    }
}

// MARK: - Free functions that run off MainActor
// nonisolated opts out of the default @MainActor isolation set by the project.

// macOS ships two separate ping binaries and they are NOT interchangeable:
// /sbin/ping speaks IPv4 only and answers any IPv6 literal with
// "cannot resolve <addr>: Unknown host", while /sbin/ping6 speaks IPv6.
// /sbin/ping also rejects a -6 flag outright, so the binary is the only switch.
nonisolated func pingExecutable(for address: String) -> String {
    address.contains(":") ? "/sbin/ping6" : "/sbin/ping"
}

// Pulls the peer address out of a reply line, handling both families:
//   IPv4  "64 bytes from 8.8.8.8: icmp_seq=0 ttl=118 time=12.3 ms"
//   IPv6  "16 bytes from 2606:4700:4700::1111, icmp_seq=0 hlim=57 time=11.4 ms"
// Splitting on ":" (as this used to) truncates every IPv6 address to its first
// group, so stop at the real separators instead and strip the trailing punctuation.
nonisolated func extractReplyIP(_ line: String) -> String? {
    guard let from = line.range(of: "from ") else { return nil }
    // Only the *trailing* punctuation is a separator. Trimming both ends (as this
    // used to) ate the leading colons of an address like "::1", reporting it as "1".
    var token = line[from.upperBound...].prefix(while: { $0 != " " && $0 != "," })
    while let last = token.last, last == ":" || last == "," { token = token.dropLast() }
    return token.isEmpty ? nil : String(token)
}

// True for reply lines and transport errors that mean "this ping did not succeed".
// Matched case-insensitively because the wording differs between ping and ping6.
// Hoisted out of the function: this runs once per line of a stream that never
// stops, so rebuilding the literal each time was pure waste.
private nonisolated let pingFailurePhrases = [
    "timeout", "unreachable", "cannot resolve", "no route", "network is down",
    "time to live exceeded", "prohibited", "frag needed", "host is down",
    "getaddrinfo", "not permitted", "filtered", "parameter problem",
    "source quench", "redirect", "bad checksum", "net unknown", "host unknown",
]

// Purely informational ICMP notices. They are printed *alongside* the packet
// they relate to, not instead of it, so a live stream must not count one as a
// lost packet — if the packet really was lost, ping prints its own
// "Request timeout for icmp_seq N" line right after.
private nonisolated let pingNoticePhrases = ["redirect", "source quench"]

nonisolated func isPingFailureLine(_ line: String) -> Bool {
    let l = line.lowercased()
    return pingFailurePhrases.contains { l.contains($0) }
}

nonisolated func isPingNoticeLine(_ line: String) -> Bool {
    let l = line.lowercased()
    return pingNoticePhrases.contains { l.contains($0) }
}

/// The resolved address as printed in ping's banner:
///   "PING google.com (142.250.204.78): 56 data bytes"
///   "PING6(56=40+8+8 bytes) 2001:db8::1 --> 2606:4700:4700::1111"
nonisolated func pingBannerIP(_ line: String) -> String? {
    guard line.hasPrefix("PING") else { return nil }
    if let open = line.range(of: "("), let close = line.range(of: ")"),
       open.upperBound <= close.lowerBound {
        let inner = String(line[open.upperBound..<close.lowerBound])
        if !inner.contains(" "), inner.contains(".") || inner.contains(":") {
            return inner
        }
    }
    if let arrow = line.range(of: "--> ") {
        let tail = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { return tail }
    }
    return nil
}

/// The round-trip time carried by a reply line, in milliseconds.
nonisolated func pingReplyLatency(_ line: String) -> Double? {
    guard line.contains("bytes from"), let range = line.range(of: "time=") else { return nil }
    return Double(String(line[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." })))
}

// MARK: - Single-line parsing (used by the continuous stream)

nonisolated enum PingLineEvent: Sendable {
    /// ping told us which address it actually resolved to.
    case banner(String)
    /// This line settles one packet, one way or the other.
    case result(PingResult)
}

/// Verdict for one line of a continuously running ping.
///
/// `headerIP` is the banner address seen so far, used when a line has no source
/// of its own (a timeout line names no host).
nonisolated func parsePingLine(_ rawLine: String, address: String, headerIP: String) -> PingLineEvent? {
    let t = rawLine.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }

    if let ip = pingBannerIP(t) { return .banner(ip) }
    // A banner we could not read an address out of still is not a verdict.
    if t.hasPrefix("PING") { return nil }

    // Summary lines belong to a run that is ending, not to a packet.
    if t.hasPrefix("---") || t.contains("round-trip") || t.contains("packets transmitted") {
        return nil
    }

    if t.hasPrefix("ping:") || t.hasPrefix("ping6:") || t.hasPrefix("usage:") {
        return .result(PingResult(isSuccess: false, resolvedIP: headerIP, latency: nil, message: t))
    }

    if let ms = pingReplyLatency(t) {
        // A "(DUP!)" line is a second copy of a reply that was already counted;
        // scoring it again inflates the success count past packets actually sent.
        if t.contains("(DUP!)") { return nil }
        return .result(PingResult(isSuccess: true,
                                  resolvedIP: extractReplyIP(t) ?? headerIP,
                                  latency: ms, message: t))
    }

    // See pingNoticePhrases: the packet's real verdict is still coming.
    if isPingNoticeLine(t) { return nil }

    if isPingFailureLine(t) {
        return .result(PingResult(isSuccess: false, resolvedIP: headerIP, latency: nil, message: t))
    }
    return nil
}

// MARK: - PingStream (one long-lived ping per host)
//
// The session used to run `ping -c 1` once per tick. At 20 hosts on a 0.5 s
// interval that forked a setuid-root binary 40 times a second, and every fork
// paid DNS resolution and socket setup again. `ping -i <interval>` does the same
// work in one process per host: it is line-buffered through a pipe, and with -W
// it prints its own "Request timeout for icmp_seq N" for a lost packet, so each
// line out is exactly one packet's verdict.

/// -i is the send interval; -W is the per-reply wait, in milliseconds.
/// ping6 accepts neither -W nor -t, so on IPv6 the stream watchdog below is the
/// only reply timeout there is.
nonisolated func pingStreamArguments(for address: String, interval: Double, timeout: Double) -> [String] {
    // Below 0.1 s -i is root-only; PingViewModel.minInterval already sits above it.
    let wait = String(format: "%.2f", max(0.1, interval))
    if address.contains(":") { return ["-i", wait, address] }
    return ["-i", wait, "-W", "\(max(1, Int((timeout * 1000).rounded())))", address]
}

private nonisolated final class PingStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastVerdict = ContinuousClock.now
    private var header = ""

    var headerIP: String {
        lock.lock(); defer { lock.unlock() }
        return header
    }

    func setHeaderIP(_ ip: String) {
        lock.lock(); header = ip; lock.unlock()
    }

    func markVerdict() {
        lock.lock(); lastVerdict = .now; lock.unlock()
    }

    func hasBeenQuiet(longerThan limit: Duration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ContinuousClock.now - lastVerdict > limit
    }
}

/// Splits the pipe into lines and turns each one into a verdict.
private nonisolated final class PingLineReader: @unchecked Sendable {
    let pipe = Pipe()

    private let lock = NSLock()
    private var buffer = Data()
    private let address: String
    private let state: PingStreamState
    private let onResult: @Sendable (PingResult) -> Void

    init(address: String, state: PingStreamState, onResult: @escaping @Sendable (PingResult) -> Void) {
        self.address = address
        self.state = state
        self.onResult = onResult
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                // Write end closed: the child is gone. The termination handler
                // does the rest; just stop being called back in a tight loop.
                self.stop()
                return
            }
            self.ingest(chunk)
        }
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Picks up anything still buffered after the child exits, then detaches.
    func drainAndStop() {
        stop()
        let rest = pipe.fileHandleForReading.availableData
        if !rest.isEmpty { ingest(rest) }
    }

    private func ingest(_ chunk: Data) {
        var lines: [String] = []

        lock.lock()
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        // A run that never emits a newline must not grow without bound.
        if buffer.count > 64 * 1024 { buffer.removeAll(keepingCapacity: false) }
        lock.unlock()

        for line in lines {
            switch parsePingLine(line, address: address, headerIP: state.headerIP) {
            case .banner(let ip):
                state.setHeaderIP(ip)
            case .result(let result):
                state.markVerdict()
                onResult(result)
            case nil:
                break
            }
        }
    }
}

nonisolated final class PingStream: @unchecked Sendable {
    /// One element per packet, for as long as the underlying ping keeps running.
    /// Finishes when the child exits (bad route, killed) so the caller can decide
    /// whether to respawn.
    let results: AsyncStream<PingResult>

    private let continuation: AsyncStream<PingResult>.Continuation

    init(address: String, interval: Double, timeout: Double) {
        // Drop stale packets rather than stall the reader if the UI falls behind.
        let (stream, continuation) = AsyncStream<PingResult>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        results = stream
        self.continuation = continuation

        let state = PingStreamState()
        let reader = PingLineReader(address: address, state: state) { result in
            continuation.yield(result)
        }
        let box = ProcessBox(
            executable: pingExecutable(for: address),
            arguments: pingStreamArguments(for: address, interval: interval, timeout: timeout),
            pipe: reader.pipe
        )

        // Backstop, and the only reply timeout on IPv6: if no line has settled a
        // packet for longer than one interval plus the reply deadline, report the
        // loss ourselves rather than letting the row sit on a stale "OK".
        let quietLimit = Duration.seconds(interval + max(timeout, 1.0))
        let tick = Duration.seconds(max(0.25, interval / 2))
        let watchdog = Task.detached(priority: .utility) { [state] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled else { return }
                guard state.hasBeenQuiet(longerThan: quietLimit) else { continue }
                state.markVerdict()
                continuation.yield(PingResult(isSuccess: false, resolvedIP: state.headerIP,
                                              latency: nil,
                                              message: "Request timeout for \(address)"))
            }
        }

        continuation.onTermination = { [box, reader] _ in
            watchdog.cancel()
            box.terminate()
            reader.stop()
        }

        box.setTerminationHandler { [reader] _ in
            reader.drainAndStop()
            continuation.finish()
        }

        reader.start()
        do {
            try box.run()
        } catch {
            continuation.yield(PingResult(isSuccess: false, resolvedIP: "", latency: nil,
                                          message: "Launch error: \(error.localizedDescription)"))
            continuation.finish()
        }
    }

    /// Ends the stream and kills the child. Safe to call more than once.
    func cancel() {
        continuation.finish()
    }
}

// MARK: - LogEntry

// Same reasoning as PingResult: created inside a detached ping task.
nonisolated struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let isSuccess: Bool
    let latency: Double?
    let message: String
}

// MARK: - PingStatus

enum PingStatus {
    case idle, running, success, failed

    var dotColor: Color {
        switch self {
        case .idle:    return .gray
        case .running: return .yellow
        case .success: return .green
        case .failed:  return .red
        }
    }

    var label: String {
        switch self {
        case .idle:    return "Idle"
        case .running: return "..."
        case .success: return "OK"
        case .failed:  return "Fail"
        }
    }
}

// MARK: - PingHost

@MainActor
final class PingHost: ObservableObject, Identifiable {
    let id = UUID()
    let address: String

    @Published var resolvedIP: String = ""
    @Published var status: PingStatus = .idle
    @Published var latency: Double? = nil
    @Published var successCount: Int = 0
    @Published var failCount: Int = 0
    @Published var log: [LogEntry] = []
    @Published var isActive: Bool = false   // true while a PingSession is running
    private(set) var generation: Int = 0    // incremented on reset; tasks gate updates on this

    var successRate: Double {
        let total = successCount + failCount
        guard total > 0 else { return 0 }
        return Double(successCount) / Double(total) * 100
    }

    init(address: String) {
        self.address = address
    }

    func addLog(isSuccess: Bool, latency: Double?, message: String) {
        let entry = LogEntry(timestamp: Date(), isSuccess: isSuccess, latency: latency, message: message)
        log.insert(entry, at: 0)
        if log.count > 500 { log.removeLast() }
    }

    func resetStats() {
        generation += 1   // invalidates every in-flight task update for this host
        successCount = 0
        failCount = 0
        latency = nil
        resolvedIP = ""
        log.removeAll()
        status = .idle
        isActive = false
    }
}

// MARK: - PingSession
// Uses Task.detached so the ping stream is consumed off the MainActor (parallel,
// non-blocking). PingStream is nonisolated and delivers one PingResult per packet
// from a single long-lived ping process; UI updates hop back via MainActor.run {}.

@MainActor
final class PingSession {
    private weak var host: PingHost?
    private var pingTask: Task<Void, Never>?
    // Incremented by stop(). A cancelled task's trailing cleanup captures the
    // epoch it started with and no-ops if it was superseded — otherwise an old
    // task's cleanup can overwrite a freshly restarted session's state
    // (isActive stuck on false, status stuck on idle while pinging).
    private var epoch = 0

    init(host: PingHost) {
        self.host = host
    }

    func start(interval: Double, timeout: Double) {
        stop()
        let myEpoch = epoch
        guard let host else { return }
        let address = host.address
        let gen = host.generation   // capture current generation; any resetStats() call increments this
        host.isActive = true
        host.status = .running

        pingTask = Task.detached(priority: .userInitiated) { [weak self] in
            // One ping process stays up for as long as it will run. It only ends
            // when the host is unroutable or the child is killed, so the outer
            // loop is a respawn-with-backoff, not a per-packet loop.
            while !Task.isCancelled {
                let stream = PingStream(address: address, interval: interval, timeout: timeout)

                await withTaskCancellationHandler {
                    for await result in stream.results {
                        guard !Task.isCancelled else { break }

                        // Both guards matter on the way back in:
                        //  - generation: resetStats() ran while this packet was in
                        //    flight, so the result belongs to the cleared counters
                        //    and must be dropped.
                        //  - epoch: stop() ran after the isCancelled check above but
                        //    before this hop was scheduled. Cancellation alone can't
                        //    be re-checked here — the task is gone — and without the
                        //    epoch guard a late result lands after Stop, flipping a
                        //    stopped host back to OK/Fail and bumping its counter
                        //    while the toolbar still reads "Stopped".
                        await MainActor.run { [weak self] in
                            guard let self, self.epoch == myEpoch,
                                  let host = self.host,
                                  host.generation == gen else { return }
                            if result.isSuccess {
                                if !result.resolvedIP.isEmpty { host.resolvedIP = result.resolvedIP }
                                host.latency = result.latency
                                host.status = .success
                                host.successCount += 1
                            } else {
                                host.latency = nil
                                host.status = .failed
                                host.failCount += 1
                            }
                            host.addLog(isSuccess: result.isSuccess, latency: result.latency,
                                        message: result.message)
                        }
                    }
                } onCancel: {
                    // The `for await` cannot see cancellation while parked on the
                    // next element, so end the stream from the outside.
                    stream.cancel()
                }

                guard !Task.isCancelled else { break }
                // The child exited on its own — an unroutable host makes ping quit
                // immediately. Wait one interval before respawning so a permanently
                // broken host retries at the configured cadence instead of spinning.
                try? await Task.sleep(for: .seconds(interval))
            }
            await MainActor.run { [weak self] in
                // Skip cleanup if stop()/start() superseded this task while the
                // hop to MainActor was queued — the new session owns the state now.
                guard let self, self.epoch == myEpoch else { return }
                self.host?.isActive = false
                self.host?.status = .idle
            }
        }
    }

    func stop() {
        epoch += 1
        pingTask?.cancel()
        pingTask = nil
        host?.isActive = false
        host?.status = .idle
    }
}

// MARK: - AppTheme

enum AppTheme: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - PingViewModel

@MainActor
final class PingViewModel: ObservableObject {
    @Published var hosts: [PingHost] = []
    @Published var selectedHostIDs: Set<UUID> = []
    @Published var interval: Double
    // Reply deadline, deliberately independent of `interval` — see PingSession.start.
    @Published var pingTimeout: Double
    @Published var theme: AppTheme

    // @Published so toolbar buttons re-render the moment sessions are added/removed
    @Published private(set) var sessions: [UUID: PingSession] = [:]

    // nil when 0 or 2+ hosts are selected (used by single-host log view)
    var selectedHost: PingHost? {
        guard selectedHostIDs.count == 1 else { return nil }
        return hosts.first { selectedHostIDs.contains($0.id) }
    }
    var selectedHosts: [PingHost] { hosts.filter { selectedHostIDs.contains($0.id) } }
    var anyActive:   Bool { !sessions.isEmpty }
    var anyInactive: Bool { !hosts.isEmpty && sessions.count < hosts.count }

    static let defaultPingTimeout: Double = 3.0
    static let minPingTimeout: Double = 0.5
    static let maxPingTimeout: Double = 15.0
    static let minInterval: Double = 0.5

    // When false, no ping sessions/processes are spawned (used by unit tests
    // to exercise host/selection logic hermetically, without real /sbin/ping).
    private let autoStart: Bool

    init(autoStart: Bool = true) {
        self.autoStart = autoStart
        let saved = UserDefaults.standard.double(forKey: "pingInterval")
        interval = saved > 0 ? saved : 1.0
        let savedTimeout = UserDefaults.standard.double(forKey: "pingTimeout")
        pingTimeout = savedTimeout > 0 ? savedTimeout : Self.defaultPingTimeout
        let savedTheme = UserDefaults.standard.string(forKey: "appTheme") ?? "system"
        theme = AppTheme(rawValue: savedTheme) ?? .system
        loadHosts()
    }

    // These are already @MainActor. Hopping through `Task { @MainActor in }`
    // only deferred the mutation by a turn, so a caller that read the property
    // right back saw the old value, and two rapid changes could land out of order.
    func setTheme(_ t: AppTheme) {
        theme = t
        UserDefaults.standard.set(t.rawValue, forKey: "appTheme")
    }

    func addHost(_ address: String) {
        let a = address.trimmingCharacters(in: .whitespaces)
        // A leading "-" would be handed to /sbin/ping as an option, not a host
        // (there is no "--" separator on macOS ping), so reject it outright.
        guard !a.isEmpty, !a.hasPrefix("-"),
              !hosts.contains(where: { $0.address.lowercased() == a.lowercased() })
        else { return }
        let host = PingHost(address: a)
        hosts.append(host)
        startSession(for: host)
        saveHosts()
    }

    func removeHost(_ host: PingHost) {
        sessions[host.id]?.stop()
        sessions.removeValue(forKey: host.id)
        selectedHostIDs.remove(host.id)
        hosts.removeAll { $0.id == host.id }
        saveHosts()
    }

    func stopAll() {
        for host in hosts {
            sessions[host.id]?.stop()
            sessions.removeValue(forKey: host.id)
        }
    }

    // Start only hosts that have no active session (keeps stats)
    func resumeAll() {
        for host in hosts where sessions[host.id] == nil {
            startSession(for: host)
        }
    }

    // Stop all, reset stats, then restart
    func restartAll() {
        for host in hosts {
            sessions[host.id]?.stop()
            sessions.removeValue(forKey: host.id)
            host.resetStats()
            startSession(for: host)
        }
    }

    func applyInterval(_ newVal: Double) {
        interval = max(Self.minInterval, newVal)
        UserDefaults.standard.set(interval, forKey: "pingInterval")
        restartActiveSessions()
    }

    func applyTimeout(_ newVal: Double) {
        pingTimeout = min(Self.maxPingTimeout, max(Self.minPingTimeout, newVal))
        UserDefaults.standard.set(pingTimeout, forKey: "pingTimeout")
        restartActiveSessions()
    }

    /// Re-arms every running host against the current interval/timeout.
    private func restartActiveSessions() {
        for host in hosts where host.isActive {
            sessions[host.id]?.stop()
            sessions.removeValue(forKey: host.id)
            startSession(for: host)
        }
    }

    func resetStats(for host: PingHost) {
        sessions[host.id]?.stop()
        sessions.removeValue(forKey: host.id)
        host.resetStats()
        startSession(for: host)
    }

    private func startSession(for host: PingHost) {
        guard autoStart else { return }
        let s = PingSession(host: host)
        sessions[host.id] = s
        s.start(interval: interval, timeout: pingTimeout)
    }

    private func saveHosts() {
        UserDefaults.standard.set(hosts.map(\.address), forKey: "savedHosts")
    }

    private func loadHosts() {
        guard let addrs = UserDefaults.standard.stringArray(forKey: "savedHosts") else { return }
        for a in addrs {
            let host = PingHost(address: a)
            hosts.append(host)
            startSession(for: host)
        }
    }
}

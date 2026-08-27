//
//  SheepPingTests.swift
//  SheepPingTests
//
//  Created by Bestchaan on 2/5/2569 BE.
//

import Foundation
import Testing
@testable import SheepPing

// MARK: - Regression tests for the bugs found in the 2026-08-24 audit

// B2: /sbin/ping is IPv4-only on macOS — it answers an IPv6 literal with
// "cannot resolve <addr>: Unknown host" and rejects -6 — so the binary itself
// has to be the switch.
@Suite("pingExecutable (B2: IPv6)")
struct PingExecutableTests {

    @Test func ipv4LiteralUsesPing() {
        #expect(pingExecutable(for: "8.8.8.8") == "/sbin/ping")
    }

    @Test func hostnameUsesPing() {
        #expect(pingExecutable(for: "google.com") == "/sbin/ping")
    }

    @Test func ipv6LiteralUsesPing6() {
        #expect(pingExecutable(for: "2606:4700:4700::1111") == "/sbin/ping6")
    }

    @Test func ipv6LoopbackUsesPing6() {
        #expect(pingExecutable(for: "::1") == "/sbin/ping6")
    }
}

// B2: the reply-line IP used to be cut at the first ":", which truncated every
// IPv6 address to its leading group ("2606:4700:4700::1111" -> "2606").
@Suite("extractReplyIP (B2: IPv6)")
struct ExtractReplyIPTests {

    @Test func ipv4ReplyStripsTrailingColon() {
        let line = "64 bytes from 8.8.8.8: icmp_seq=0 ttl=118 time=12.3 ms"
        #expect(extractReplyIP(line) == "8.8.8.8")
    }

    @Test func ipv6ReplyKeepsEveryGroup() {
        // Real /sbin/ping6 output — note the comma separator, not a colon.
        let line = "16 bytes from 2606:4700:4700::1111, icmp_seq=0 hlim=52 time=53.229 ms"
        #expect(extractReplyIP(line) == "2606:4700:4700::1111")
    }

    // Trimming ":" from *both* ends ate the leading colons of the IPv6 loopback
    // and reported it as "1".
    @Test func ipv6LoopbackKeepsItsLeadingColons() {
        let line = "16 bytes from ::1, icmp_seq=0 hlim=64 time=0.081 ms"
        #expect(extractReplyIP(line) == "::1")
    }

    @Test func lineWithoutFromYieldsNil() {
        #expect(extractReplyIP("1 packets transmitted, 0 packets received") == nil)
    }
}

// MARK: - PingHost

@Suite("PingHost")
@MainActor
struct PingHostTests {

    @Test func successRateIsZeroWithNoPings() {
        let host = PingHost(address: "8.8.8.8")
        #expect(host.successRate == 0)
    }

    @Test func successRateMath() {
        let host = PingHost(address: "8.8.8.8")
        host.successCount = 3
        host.failCount = 1
        #expect(host.successRate == 75)
    }

    @Test func logIsNewestFirst() {
        let host = PingHost(address: "8.8.8.8")
        host.addLog(isSuccess: true, latency: 1.0, message: "first")
        host.addLog(isSuccess: false, latency: nil, message: "second")
        #expect(host.log.count == 2)
        #expect(host.log[0].message == "second")
        #expect(host.log[1].message == "first")
    }

    @Test func logCapsAt500Entries() {
        let host = PingHost(address: "8.8.8.8")
        for i in 0..<600 {
            host.addLog(isSuccess: true, latency: 1.0, message: "entry-\(i)")
        }
        #expect(host.log.count == 500)
        // Oldest entries are evicted; newest stays at the front.
        #expect(host.log[0].message == "entry-599")
        #expect(host.log[499].message == "entry-100")
    }

    @Test func resetStatsClearsEverythingAndBumpsGeneration() {
        let host = PingHost(address: "8.8.8.8")
        host.successCount = 5
        host.failCount = 2
        host.latency = 12.3
        host.resolvedIP = "8.8.8.8"
        host.addLog(isSuccess: true, latency: 12.3, message: "x")
        let genBefore = host.generation

        host.resetStats()

        #expect(host.successCount == 0)
        #expect(host.failCount == 0)
        #expect(host.latency == nil)
        #expect(host.resolvedIP.isEmpty)
        #expect(host.log.isEmpty)
        #expect(host.status == .idle)
        #expect(!host.isActive)
        #expect(host.generation == genBefore + 1)
    }
}

// MARK: - PingViewModel (hermetic: autoStart = false, no real ping processes)

// .serialized: Swift Testing runs tests in parallel by default, but every
// PingViewModel reads/writes the shared UserDefaults "savedHosts" key
// (loadHosts/saveHosts), so parallel runs race and flake.
@Suite("PingViewModel", .serialized)
@MainActor
struct PingViewModelTests {

    init() {
        // Isolate from the developer's real saved state.
        UserDefaults.standard.set([String](), forKey: "savedHosts")
    }

    @Test func addHostTrimsWhitespace() {
        let vm = PingViewModel(autoStart: false)
        vm.addHost("  8.8.8.8  ")
        #expect(vm.hosts.map(\.address) == ["8.8.8.8"])
    }

    @Test func addHostIgnoresEmpty() {
        let vm = PingViewModel(autoStart: false)
        vm.addHost("   ")
        #expect(vm.hosts.isEmpty)
    }

    // A leading "-" would reach /sbin/ping as an option (there is no "--"
    // separator), so it must never become a host.
    @Test func addHostRejectsFlagLikeInput() {
        let vm = PingViewModel(autoStart: false)
        vm.addHost("-v")
        vm.addHost("  -c 100000")
        #expect(vm.hosts.isEmpty)
    }

    @Test func addHostDeduplicatesCaseInsensitively() {
        let vm = PingViewModel(autoStart: false)
        vm.addHost("Google.com")
        vm.addHost("google.com")
        #expect(vm.hosts.count == 1)
    }

    @Test func removeHostCleansUpSelection() {
        let vm = PingViewModel(autoStart: false)
        vm.addHost("8.8.8.8")
        let host = vm.hosts[0]
        vm.selectedHostIDs = [host.id]
        vm.removeHost(host)
        #expect(vm.hosts.isEmpty)
        #expect(vm.selectedHostIDs.isEmpty)
    }

    @Test func selectedHostRequiresExactlyOneSelection() {
        let vm = PingViewModel(autoStart: false)
        vm.addHost("8.8.8.8")
        vm.addHost("1.1.1.1")
        #expect(vm.selectedHost == nil)
        vm.selectedHostIDs = [vm.hosts[0].id]
        #expect(vm.selectedHost?.address == "8.8.8.8")
        vm.selectedHostIDs.insert(vm.hosts[1].id)
        #expect(vm.selectedHost == nil)
    }

    @Test func applyIntervalClampsToMinimum() async {
        let vm = PingViewModel(autoStart: false)
        vm.applyInterval(0.1)
        // applyInterval hops through a MainActor task — yield so it can run.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.interval == 0.5)
    }

    // B1: the reply deadline is its own setting now. It used to be
    // min(interval, 2.0), which failed every host slower than the interval.
    @Test func pingTimeoutDefaultsAboveOneSecond() {
        UserDefaults.standard.removeObject(forKey: "pingTimeout")
        let vm = PingViewModel(autoStart: false)
        #expect(vm.pingTimeout == PingViewModel.defaultPingTimeout)
        #expect(vm.pingTimeout >= 1.0)
    }

    @Test func applyTimeoutClampsToBounds() async {
        let vm = PingViewModel(autoStart: false)
        vm.applyTimeout(0.01)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.pingTimeout == PingViewModel.minPingTimeout)

        vm.applyTimeout(9_999)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.pingTimeout == PingViewModel.maxPingTimeout)
    }

    @Test func pingTimeoutIsIndependentOfInterval() async {
        let vm = PingViewModel(autoStart: false)
        vm.applyTimeout(5.0)
        vm.applyInterval(0.5)
        try? await Task.sleep(for: .milliseconds(150))
        // The old code derived the deadline from the interval; a 0.5 s interval
        // must no longer drag the reply deadline down with it.
        #expect(vm.interval == 0.5)
        #expect(vm.pingTimeout == 5.0)
    }
}

// MARK: - Continuous ping stream
//
// The session used to fork `ping -c 1` on every tick. These cover the streaming
// replacement: argument shape per address family, per-line verdicts, and a live
// run that proves one process really does keep emitting.

@Suite("pingStreamArguments")
struct PingStreamArgumentsTests {

    @Test func ipv4CarriesIntervalAndPerReplyWait() {
        #expect(pingStreamArguments(for: "8.8.8.8", interval: 1.0, timeout: 3.0)
                == ["-i", "1.00", "-W", "3000", "8.8.8.8"])
    }

    @Test func ipv6OmitsTheWaitFlagPing6DoesNotHave() {
        let args = pingStreamArguments(for: "::1", interval: 0.5, timeout: 3.0)
        #expect(args == ["-i", "0.50", "::1"])
        #expect(!args.contains("-W"))
        #expect(!args.contains("-t"))
    }

    // -i below 0.1 s is root-only; anything that low must not reach the binary.
    @Test func intervalNeverDropsBelowTheUnprivilegedFloor() {
        let args = pingStreamArguments(for: "8.8.8.8", interval: 0.01, timeout: 1.0)
        #expect(args[1] == "0.10")
    }

    // -W 0 would mean "wait forever".
    @Test func waitIsNeverZeroMilliseconds() {
        let args = pingStreamArguments(for: "8.8.8.8", interval: 1.0, timeout: 0.0001)
        #expect(args[3] == "1")
    }
}

@Suite("parsePingLine")
struct ParsePingLineTests {

    private func result(_ line: String, headerIP: String = "") -> PingResult? {
        if case .result(let r)? = parsePingLine(line, address: "h", headerIP: headerIP) { return r }
        return nil
    }

    @Test func bannerYieldsTheResolvedAddress() {
        guard case .banner(let ip)? = parsePingLine("PING google.com (142.250.4.206): 56 data bytes",
                                                    address: "google.com", headerIP: "") else {
            Issue.record("expected a banner event"); return
        }
        #expect(ip == "142.250.4.206")
    }

    @Test func ping6BannerYieldsTheDestination() {
        guard case .banner(let ip)? = parsePingLine("PING6(56=40+8+8 bytes) ::1 --> 2606:4700:4700::1111",
                                                    address: "h", headerIP: "") else {
            Issue.record("expected a banner event"); return
        }
        #expect(ip == "2606:4700:4700::1111")
    }

    @Test func replyLineIsASuccessWithLatency() {
        let r = result("64 bytes from 8.8.8.8: icmp_seq=3 ttl=118 time=12.3 ms")
        #expect(r?.isSuccess == true)
        #expect(r?.latency == 12.3)
        #expect(r?.resolvedIP == "8.8.8.8")
    }

    // What `ping -W` prints for a lost packet. It names no host, so the banner
    // address has to carry through.
    @Test func requestTimeoutLineIsAFailureThatKeepsTheBannerIP() {
        let r = result("Request timeout for icmp_seq 7", headerIP: "203.0.113.1")
        #expect(r?.isSuccess == false)
        #expect(r?.latency == nil)
        #expect(r?.resolvedIP == "203.0.113.1")
    }

    @Test func binaryDiagnosticIsAFailure() {
        #expect(result("ping: sendto: No route to host")?.isSuccess == false)
    }

    // A duplicate reply is a second copy of a packet that was already scored —
    // counting it again pushes the success count past packets actually sent.
    @Test func duplicateReplyIsNotAVerdict() {
        #expect(parsePingLine("64 bytes from 8.8.8.8: icmp_seq=2 ttl=118 time=12.3 ms (DUP!)",
                              address: "h", headerIP: "") == nil)
    }

    // An informational notice is not a verdict: the packet's own reply or
    // timeout line follows it, and counting both would double-count the packet.
    @Test func redirectNoticeIsNotAVerdict() {
        #expect(parsePingLine("92 bytes from 10.0.0.1: Redirect Host(New addr: 10.0.0.9)",
                              address: "h", headerIP: "") == nil)
    }

    // ── Migrated from the old whole-output parser ──────────────────────────
    //
    // B3: ping's own diagnostics and ICMP error replies used to collapse into a
    // generic "No response from <host>", so a permissions failure looked exactly
    // like a dead host. Each one has to come back as its own verdict.

    @Test func socketPermissionErrorIsSurfaced() {
        let r = result("ping: socket: Operation not permitted")
        #expect(r?.isSuccess == false)
        #expect(r?.message.contains("Operation not permitted") == true)
    }

    @Test func usageErrorIsSurfaced() {
        let r = result("usage: ping [-AaDdfnoQqRrv] [-b boundif] host")
        #expect(r?.isSuccess == false)
        #expect(r?.message.contains("usage:") == true)
    }

    @Test func ping6BadHostnameSurfacesGetaddrinfo() {
        let r = result("ping6: getaddrinfo -- nodename nor servname provided, or not known")
        #expect(r?.isSuccess == false)
        #expect(r?.message.contains("getaddrinfo") == true)
    }

    @Test func ping6NoRouteIsFailure() {
        let r = result("ping6: UDP connect: No route to host")
        #expect(r?.isSuccess == false)
        #expect(r?.message.contains("No route to host") == true)
    }

    // These carry "bytes from" but no "time=", so a naive success check would
    // have misread every one of them as a reply.

    @Test func timeToLiveExceededIsFailureNotSuccess() {
        let r = result("36 bytes from 10.0.0.1: Time to live exceeded", headerIP: "203.0.113.9")
        #expect(r?.isSuccess == false)
        #expect(r?.latency == nil)
        #expect(r?.message.contains("Time to live exceeded") == true)
    }

    @Test func hostUnreachableIsFailureAndKeepsTheBannerIP() {
        let r = result("92 bytes from 10.0.0.1: Destination Host Unreachable", headerIP: "192.0.2.1")
        #expect(r?.isSuccess == false)
        #expect(r?.latency == nil)
        #expect(r?.resolvedIP == "192.0.2.1")
    }

    @Test func administrativelyProhibitedIsFailure() {
        #expect(result("36 bytes from 10.0.0.1: Communication prohibited by filter")?.isSuccess == false)
    }

    @Test func fragNeededIsFailure() {
        #expect(result("36 bytes from 10.0.0.1: frag needed and DF set (MTU 1400)")?.isSuccess == false)
    }

    @Test func subMillisecondLatency() {
        #expect(result("64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.042 ms")?.latency == 0.042)
    }

    @Test func fourDigitLatency() {
        #expect(result("64 bytes from 10.0.0.1: icmp_seq=0 ttl=64 time=1234 ms")?.latency == 1234)
    }

    @Test func ping6ReplyKeepsTheFullAddress() {
        let r = result("16 bytes from 2606:4700:4700::1111, icmp_seq=0 hlim=52 time=53.229 ms")
        #expect(r?.isSuccess == true)
        #expect(r?.resolvedIP == "2606:4700:4700::1111")
        #expect(r?.latency == 53.229)
    }

    @Test func cannotResolveHostnameIsFailure() {
        #expect(result("ping: cannot resolve no-such-host.invalid: Unknown host")?.isSuccess == false)
    }

    @Test func networkIsDownIsFailure() {
        #expect(result("ping: sendto: Network is down")?.isSuccess == false)
    }

    @Test func summaryAndBlankLinesAreNotVerdicts() {
        #expect(parsePingLine("", address: "h", headerIP: "") == nil)
        #expect(parsePingLine("--- 8.8.8.8 ping statistics ---", address: "h", headerIP: "") == nil)
        #expect(parsePingLine("1 packets transmitted, 1 packets received, 0.0% packet loss",
                              address: "h", headerIP: "") == nil)
        #expect(parsePingLine("round-trip min/avg/max/stddev = 12.3/12.3/12.3/0.0 ms",
                              address: "h", headerIP: "") == nil)
    }
}

@Suite("PingStream (live)", .serialized)
struct PingStreamLiveTests {

    private func take(_ stream: PingStream, count: Int, giveUpAfter: Duration) async -> [PingResult] {
        let collected: [PingResult] = await withTaskGroup(of: [PingResult].self) { group in
            group.addTask {
                var out: [PingResult] = []
                for await r in stream.results {
                    out.append(r)
                    if out.count >= count { break }
                }
                return out
            }
            group.addTask {
                try? await Task.sleep(for: giveUpAfter)
                stream.cancel()
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
        stream.cancel()
        return collected
    }

    // One process, many packets: three replies must arrive roughly two intervals
    // apart, not three process launches later.
    @Test func loopbackKeepsEmittingFromASingleProcess() async {
        let stream = PingStream(address: "127.0.0.1", interval: 0.5, timeout: 2.0)
        let start = ContinuousClock.now
        let results = await take(stream, count: 3, giveUpAfter: .seconds(8))
        let elapsed = ContinuousClock.now - start

        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(results.allSatisfy { $0.latency != nil })
        #expect(results.allSatisfy { $0.resolvedIP == "127.0.0.1" })
        // Two gaps of 0.5 s, plus slack. A per-tick respawn could not be faster.
        #expect(elapsed < .seconds(4))
    }

    @Test func ipv6LoopbackStreams() async {
        let stream = PingStream(address: "::1", interval: 0.5, timeout: 2.0)
        let results = await take(stream, count: 2, giveUpAfter: .seconds(8))
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(results.allSatisfy { $0.resolvedIP == "::1" })
    }

    // TEST-NET-3 swallows the packets, so -W has to turn each one into a verdict
    // rather than leaving the row stuck on its last value.
    @Test func blackHoleHostProducesFailuresNotSilence() async {
        let stream = PingStream(address: "203.0.113.1", interval: 0.5, timeout: 0.5)
        let results = await take(stream, count: 2, giveUpAfter: .seconds(10))
        #expect(results.count == 2)
        #expect(results.allSatisfy { !$0.isSuccess })
        #expect(results.allSatisfy { $0.latency == nil })
        // Each one must say why, not come back as an empty message.
        #expect(results.allSatisfy { !$0.message.isEmpty })
    }

    // An IPv6 literal has to reach
    // ping6 with an argument list ping6 accepts. Both wordings below are the
    // fingerprints of the two ways that has broken — /sbin/ping being handed the
    // literal, and ping6 rejecting a -t value it has no flag for.
    @Test func ipv6LiteralIsNeverRejectedByTheBinaryItself() async {
        let stream = PingStream(address: "2606:4700:4700::1111", interval: 0.5, timeout: 2.0)
        let results = await take(stream, count: 1, giveUpAfter: .seconds(8))
        // Only reachable on an IPv6-capable network, so assert on the failure
        // wording rather than on success.
        for r in results {
            #expect(!r.message.contains("Unknown host"))
            #expect(!r.message.contains("nodename nor servname"))
            if r.isSuccess { #expect(r.resolvedIP == "2606:4700:4700::1111") }
        }
    }

    @Test func cancelEndsTheStream() async {
        let stream = PingStream(address: "127.0.0.1", interval: 0.5, timeout: 2.0)
        _ = await take(stream, count: 1, giveUpAfter: .seconds(8))
        stream.cancel()
        // Iterating a finished stream completes instead of hanging.
        var tail: [PingResult] = []
        for await r in stream.results { tail.append(r) }
        #expect(tail.count < 100)
    }
}

// MARK: - PingSession over the stream (live)
//
// The seam that actually changed: the session now consumes a long-lived stream
// instead of awaiting one `ping -c 1` per tick. These assert the host state it
// produces, and that Stop really is the end of it.

@Suite("PingSession (live)", .serialized)
@MainActor
struct PingSessionLiveTests {

    @Test func sessionDrivesHostCountersFromTheStream() async throws {
        let host = PingHost(address: "127.0.0.1")
        let session = PingSession(host: host)
        session.start(interval: 0.5, timeout: 2.0)
        #expect(host.isActive)

        try await Task.sleep(for: .seconds(2))

        #expect(host.successCount >= 2)
        #expect(host.failCount == 0)
        #expect(host.latency != nil)
        #expect(host.resolvedIP == "127.0.0.1")
        #expect(host.log.count >= 2)
        session.stop()
    }

    // The epoch guard: a packet already in flight when Stop lands must not bump
    // a counter or flip the row back to OK while the toolbar reads "Stopped".
    @Test func stopIsFinalAndNoLateResultLands() async throws {
        let host = PingHost(address: "127.0.0.1")
        let session = PingSession(host: host)
        session.start(interval: 0.5, timeout: 2.0)
        try await Task.sleep(for: .seconds(1.5))

        session.stop()
        let settled = host.successCount + host.failCount
        #expect(settled >= 1)
        #expect(!host.isActive)

        try await Task.sleep(for: .seconds(2))
        #expect(host.successCount + host.failCount == settled)
        #expect(!host.isActive)
    }

    // resetStats() bumps the generation, which has to invalidate anything the
    // old stream still delivers.
    @Test func resetStatsDiscardsInFlightResults() async throws {
        let host = PingHost(address: "127.0.0.1")
        let session = PingSession(host: host)
        session.start(interval: 0.5, timeout: 2.0)
        try await Task.sleep(for: .seconds(1.2))
        #expect(host.successCount >= 1)

        session.stop()
        host.resetStats()
        try await Task.sleep(for: .seconds(1.5))
        #expect(host.successCount == 0)
        #expect(host.failCount == 0)
        #expect(host.log.isEmpty)
    }

    // An unroutable host makes ping exit immediately; the session must respawn
    // it on the interval rather than going quiet or spinning.
    @Test func unroutableHostKeepsReportingFailures() async throws {
        let host = PingHost(address: "203.0.113.1")
        let session = PingSession(host: host)
        session.start(interval: 0.5, timeout: 0.5)
        try await Task.sleep(for: .seconds(3))

        #expect(host.failCount >= 1)
        #expect(host.successCount == 0)
        #expect(host.latency == nil)
        session.stop()
    }
}

import Foundation
import YACWCore

/// The project's checks. `yacw-cli selftest` runs them anywhere (Command Line Tools are enough); the XCTest wrapper in
/// Tests/ runs the same function under `swift test` where XCTest exists (Xcode, CI).
final class GBox<T>: @unchecked Sendable { var v: T? }

public enum SelfTest {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print("\(ok ? "ok  " : "FAIL") \(name)"); if !ok { failures += 1 }
    }
    static func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool { a.map { abs($0 - b) < eps } ?? false }

    static func line(session: String = "s1", msg: String, req: String, ts: String, model: String = "claude-opus-5-5",
                     out: Int, cc: Int = 500, cc1h: Int = 500, sidechain: Bool = false) -> Data {
        Data("""
        {"type":"assistant","sessionId":"\(session)","timestamp":"\(ts)","cwd":"/Users/x/projetos/demo","requestId":"\(req)","isSidechain":\(sidechain),"message":{"id":"\(msg)","model":"\(model)","usage":{"input_tokens":2,"output_tokens":\(out),"cache_read_input_tokens":1000,"cache_creation_input_tokens":\(cc),"cache_creation":{"ephemeral_1h_input_tokens":\(cc1h),"ephemeral_5m_input_tokens":\(cc - cc1h)}}}}
        """.utf8)
    }

    public static func run() throws -> Int32 {
        let pricing = try PricingTable.load()

        let dedup = LogParser.records(fromLines: [
            line(msg: "m1", req: "r1", ts: "2026-10-29T10:00:00.000Z", out: 10),
            line(msg: "m1", req: "r1", ts: "2026-10-29T10:00:01.000Z", out: 195),
            line(msg: "m2", req: "r2", ts: "2026-10-29T10:01:00.000Z", out: 50),
            Data(#"{"type":"user","sessionId":"s1"}"#.utf8)])
        check(dedup.count == 2 && dedup[0].usage.output == 195, "dedup keeps last line of each (message.id, requestId)")

        let side = LogParser.records(fromLines: [
            line(msg: "m1", req: "r1", ts: "2026-10-29T10:00:00.000Z", out: 100),
            line(msg: "m9", req: "r9", ts: "2026-10-29T10:00:30.000Z", out: 300, sidechain: true)])
        let ss = Aggregation.sessions(from: side, pricing: pricing)
        check(side.filter(\.isSidechain).count == 1 && ss.count == 1 && ss[0].messages == 2 && ss[0].usage.output == 400,
              "sidechain counted in same session and flagged (synthetic)")

        // Same response present in two files (resumed session) must be counted once.
        let r = line(msg: "m1", req: "r1", ts: "2026-10-29T10:00:00.000Z", out: 100)
        let twice = Aggregation.sessions(from: LogParser.records(fromLines: [r]) + LogParser.records(fromLines: [r]), pricing: pricing)
        check(twice[0].messages == 1, "dedup across files")

        let u = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000, cacheWrite1h: 1_000_000)
        check(near(pricing.cost(model: "claude-opus-5-5", usage: u), 32.2), "opus-5-5 cost with 1h cache writes (4+20+0.2+8)")
        let mixed = TokenUsage(cacheWrite: 1_000_000, cacheWrite1h: 400_000)
        check(near(pricing.cost(model: "claude-opus-5-5", usage: mixed), 0.6 * 5 + 0.4 * 8), "5m/1h cache writes priced separately")
        check(pricing.cost(model: "claude-unknown-9", usage: u) == nil, "unknown model has no cost")
        check(near(pricing.cost(model: "claude-haiku-5-5", usage: TokenUsage(input: 100_000, output: 1_000_000)), 0.01 + 0.5), "haiku short-prompt tier")
        check(near(pricing.cost(model: "claude-haiku-5-5", usage: TokenUsage(input: 100_001, output: 1_000_000)), 0.0500005 + 2.5, 1e-6), "haiku long-prompt tier")

        let idle = Aggregation.sessions(from: LogParser.records(fromLines: [
            line(msg: "a", req: "a", ts: "2026-10-29T10:00:00.000Z", out: 1),
            line(msg: "b", req: "b", ts: "2026-10-29T10:02:00.000Z", out: 1),
            line(msg: "c", req: "c", ts: "2026-10-29T12:00:00.000Z", out: 1)]), pricing: pricing)
        check(near(idle[0].activeDuration, 120, 0.001), "active duration ignores idle gaps")

        // Cache hit denominator = input + cache read + cache write (all input).
        let h = Aggregation.cacheHitRate(TokenUsage(input: 100, output: 999, cacheRead: 800, cacheWrite: 100))
        check(near(h, 0.8), "cache hit = cacheRead / (input + cacheRead + cacheWrite)")

        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/samples")
        let s1 = try UsageEndpointDecoder.decode(Data(contentsOf: dir.appendingPathComponent("usage-response.example.json")))
        check(s1.fiveHour?.usedPercent == 42 && s1.sevenDay?.usedPercent == 17, "usage endpoint: five_hour/seven_day (sample 1)")
        check(s1.extraUsage == ExtraUsage(currency: "USD", used: 42.50), "usage endpoint: spend.used 4250 minor, exp 2 = 42.50 USD")
        check(s1.sevenDayOpus == nil && s1.sevenDaySonnet == nil, "usage endpoint: per-model windows absent when null")
        let s2 = try UsageEndpointDecoder.decode(Data(contentsOf: dir.appendingPathComponent("usage-response-no-spend.example.json")))
        check(s2.extraUsage == nil && s2.fiveHour != nil, "usage endpoint: spend null (sample 2)")

        let st = try StatuslineProvider.decode(Data(#"{"updated_at":1793272761,"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":1793286000}}}"#.utf8))
        check(st.fiveHour?.usedPercent == 50 && st.sevenDay == nil, "statusLine state decode (a window may be absent)")

        final class Box: @unchecked Sendable { var disabled = false }
        let box = Box(); let sem = DispatchSemaphore(value: 0)
        Task {
            do { _ = try await UsageEndpointProvider { Data() }.fetch() } catch { box.disabled = (error as? ProviderError) == .disabled }
            sem.signal()
        }
        sem.wait()
        check(box.disabled, "usage endpoint provider is disabled by default")


        // --- insights / history / alerts / coordinator ---
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = t0.addingTimeInterval(8 * 3600)
        let smp = [HistorySample(ts: t0.addingTimeInterval(-3000), kind: .fiveHour, percent: 20, resetsAt: reset),
                   HistorySample(ts: t0, kind: .fiveHour, percent: 30, resetsAt: reset)]
        func pr(_ st: ProjectionState?) -> Projection? { if case .ready(let p)? = st { return p }; return nil }
        let pReset = t0.addingTimeInterval(3 * 3600)          // 5h window that started 2h ago
        func hs(_ ago: TimeInterval, _ pct: Double) -> HistorySample { HistorySample(ts: t0.addingTimeInterval(-ago), kind: .fiveHour, percent: pct, resetsAt: pReset) }
        func win(_ pct: Double) -> LimitWindow { LimitWindow(kind: .fiveHour, usedPercent: pct, resetsAt: pReset) }
        let proj = pr(Insights.projection(samples: [hs(1500, 20), hs(0, 30)], current: win(30), now: t0))
        check(near(proj?.ratePerHour, 24) && proj?.exhaustsAt != nil && proj?.warn == true, "projection 5h: 10 points in 25 min = 24%/h, exhausts before reset, alerts above 20%")
        let slow = pr(Insights.projection(samples: [hs(1500, 20), hs(0, 21)], current: win(21), now: t0))
        check(slow?.exhaustsAt == nil, "projection 5h: no ETA when exhaustion is after the reset")
        let low = pr(Insights.projection(samples: [hs(1500, 1), hs(0, 19)], current: win(19), now: t0))
        check(low?.exhaustsAt != nil && low?.warn == false, "projection 5h: ETA before reset but usage <= 20% = gray pace, no alert")
        // window started 10 min ago: too early
        let young = Insights.projection(samples: [], current: LimitWindow(kind: .fiveHour, usedPercent: 6, resetsAt: t0.addingTimeInterval(5 * 3600 - 600)), now: t0)
        if case .tooEarly(let el, let need) = young { check(near(el, 600) && near(need, 900), "projection 5h: hidden before 15 min of window") } else { check(false, "projection 5h: hidden before 15 min of window") }
        // 20 min into the window, 6%: pace averaged since the start (18%/h), not a spike
        let early = pr(Insights.projection(samples: [], current: LimitWindow(kind: .fiveHour, usedPercent: 6, resetsAt: t0.addingTimeInterval(5 * 3600 - 1200)), now: t0))
        check(near(early?.ratePerHour, 18) && early?.warn == false, "projection 5h: window younger than 30 min averages since its start")
        // 30-min average, not the 60-min one: a spike 50 min ago must not count
        let spike = pr(Insights.projection(samples: [hs(3000, 0), hs(2700, 15), hs(1500, 15), hs(0, 16)], current: win(16), now: t0))
        check(near(spike?.ratePerHour, 2.4, 1e-6) && spike?.exhaustsAt == nil, "projection 5h: uses only the last 30 min of samples")

        let mem = try SQLiteHistoryStore(path: NSTemporaryDirectory() + "yacw-selftest-\(UUID().uuidString).sqlite")
        try mem.append(smp + [HistorySample(ts: t0.addingTimeInterval(-200 * 86_400), kind: .fiveHour, percent: 1, resetsAt: reset)])
        try mem.prune(olderThan: t0.addingTimeInterval(-SQLiteHistoryStore.retention))
        let back = try mem.samples(since: t0.addingTimeInterval(-300 * 86_400), kind: .fiveHour)
        check(back.count == 2 && back.last?.percent == 30, "sqlite history roundtrip + 180-day retention prune")

        let engine = AlertEngine()
        func snap(_ p: Double, _ r: Date) -> UsageSnapshot {
            UsageSnapshot(source: .statusLine, fetchedAt: t0, fiveHour: LimitWindow(kind: .fiveHour, usedPercent: p, resetsAt: r),
                          sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil, extraUsage: nil)
        }
        check(engine.evaluate(snap(80, reset)).isEmpty, "alerts: first snapshot only seeds state")
        check(engine.evaluate(snap(92, reset)).map(\.title) == ["Limite de 5h: 90%"], "alerts: crossing 90% fires once")
        check(engine.evaluate(snap(93, reset)).isEmpty, "alerts: no repeat within the same window")
        check(engine.evaluate(snap(3, reset.addingTimeInterval(5 * 3600))).map(\.title) == ["Janela de 5h renovada"], "alerts: renewal notice")

        let recs = LogParser.records(fromLines: [line(msg: "a", req: "a", ts: "2026-10-29T10:00:00.000Z", out: 1),
                                                 line(msg: "b", req: "b", ts: "2026-10-29T16:00:00.000Z", out: 1)])
        let now = LogParser.parseDate("2026-10-29T17:00:00.000Z")!
        let win = LocalEstimate.currentFiveHourWindow(records: recs, now: now)
        check(win?.start == recs[1].timestamp && win?.end == recs[1].timestamp.addingTimeInterval(5 * 3600), "estimate: new 5h window starts after the previous ended")
        check(LocalEstimate.currentFiveHourWindow(records: recs, now: now.addingTimeInterval(6 * 3600)) == nil, "estimate: nil when the last window already ended")


        // --- off-Mac heuristic (calibrated on %/US$) ---
        let base = Date(timeIntervalSince1970: 1_800_000_000), owin = base.addingTimeInterval(5 * 3600)
        func rec(_ i: Int, at: Date) -> UsageRecord {
            UsageRecord(sessionId: "s", messageId: "m\(i)", requestId: "r\(i)", timestamp: at, cwd: nil, model: "claude-opus-5-5",
                        usage: TokenUsage(output: 50_000))   // 50k out x $20/M = $1.00
        }
        var osamples = [HistorySample(ts: base, kind: .fiveHour, percent: 0, resetsAt: owin, source: .usageEndpoint)]
        var orecs: [UsageRecord] = []
        for i in 1...12 {   // 12 intervals of 10 min, $1 local, +10 points each: ratio = 10 %/US$
            let t = base.addingTimeInterval(Double(i) * 600)
            orecs.append(rec(i, at: t.addingTimeInterval(-300)))
            osamples.append(HistorySample(ts: t, kind: .fiveHour, percent: Double(i) * 10 * 0.8, resetsAt: owin, source: .usageEndpoint))
        }
        // (percent grows 8 per interval, so the calibrated ratio is 8 %/US$)
        let tOut = base.addingTimeInterval(13 * 600)
        osamples.append(HistorySample(ts: tOut, kind: .fiveHour, percent: 96 + 12, resetsAt: owin, source: .usageEndpoint)) // +12, no local cost
        let off = Insights.offMacActivity(samples: osamples, records: orecs, pricing: pricing)
        check(off.status == .ok && near(off.percentPerUSD.map { $0 }, 8, 0.01), "off-Mac: ratio calibrated from intervals with local cost (median 8 %/US$)")
        check(off.intervals.count == 1 && near(off.intervals[0].points, 12, 0.01), "off-Mac: only the jump without local cost is flagged")
        check(Insights.offMacActivity(samples: Array(osamples.prefix(4)), records: orecs, pricing: pricing).status == .insufficient(have: 3, need: 10),
              "off-Mac: insufficient calibration data is reported, not guessed")
        check(Insights.offMacActivity(samples: osamples.map { var x = $0; x.source = .statusLine; return x }, records: orecs, pricing: pricing).status == .unavailableWithoutEndpoint,
              "off-Mac: unavailable without endpoint samples")

        // --- strict decoder for source C ---
        let sampleDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/samples")
        let good = try Data(contentsOf: sampleDir.appendingPathComponent("usage-response.example.json"))
        check((try? UsageEndpointDecoder.decodeStrict(good))?.fiveHour?.usedPercent == 42, "strict decoder accepts the example sample")
        // The sample's reset times are in the past by now; coordinator tests (which run at the real clock) need live windows.
        let fresh = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200))
        let goodLive = Data(String(decoding: good, as: UTF8.self)
            .replacingOccurrences(of: #"\"resets_at\": \"[^\"]+\""#, with: "\"resets_at\": \"\(fresh)\"", options: .regularExpression).utf8)
        func rejects(_ json: String) -> Bool {
            do { _ = try UsageEndpointDecoder.decodeStrict(Data(json.utf8)); return false }
            catch { if case ProviderError.endpointChanged = error { return true }; return false }
        }
        let d7 = #""seven_day":{"utilization":5,"resets_at":"2026-11-05T08:59:59.5+00:00"}"#
        check(rejects("{" + d7 + "}") == false && (try? UsageEndpointDecoder.decodeStrict(Data(("{" + d7 + "}").utf8)))?.degraded[.fiveHour] == "five_hour ausente",
              "strict decoder: missing five_hour degrades only that window")
        check(rejects(#"{"five_hour":{"utilization":150,"resets_at":"2026-11-05T08:59:59.5+00:00"},"seven_day":{"utilization":500,"resets_at":"2026-11-05T08:59:59.5+00:00"}}"#), "strict decoder: utilization out of range in both windows = endpoint changed")
        check(rejects(#"{"five_hour":{"usage":5},"seven_day":{"utilization":5}}"#), "strict decoder: renamed fields = endpoint changed")
        check(rejects("<html>blocked</html>"), "strict decoder: non-JSON = endpoint changed")

        // --- coordinator: source C states, backoff, fallback, throttle ---
        final class Counter: @unchecked Sendable { var n = 0 }
        let calls = Counter()
        let cTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cTmp, withIntermediateDirectories: true)
        let bFile = cTmp.appendingPathComponent("state.json"); let nowE = Int(Date().timeIntervalSince1970)
        try Data("{\"updated_at\":\(nowE),\"rate_limits\":{\"five_hour\":{\"used_percentage\":30,\"resets_at\":\(nowE + 3600)}}}".utf8).write(to: bFile)
        let endpoint = UsageEndpointProvider(isEnabled: true) { calls.n += 1; throw ProviderError.sessionExpired("HTTP 401") }
        let c2 = UpdateCoordinator(entries: [.init(endpoint, minInterval: 30, isRemote: true), .init(StatuslineProvider(url: bFile))],
                                   logIndex: LogIndex(roots: [cTmp]), history: MemoryHistoryStore(), pricing: pricing)
        func block<T>(_ f: @escaping @Sendable () async -> T) -> T {
            let o = GBox<T>(); let sm = DispatchSemaphore(value: 0)
            Task { o.v = await f(); sm.signal() }
            sm.wait(); return o.v!
        }
        let t1 = Date()
        let r1s = block { await c2.refresh(now: t1) }
        check(r1s.endpoint == .sessionExpired("HTTP 401") && r1s.status == .ok(.statusLine) && r1s.snapshot?.fiveHour?.usedPercent == 30,
              "coordinator: C session expired is visible and B is used as fallback")
        let r2s = block { await c2.refresh(now: t1.addingTimeInterval(10), force: true) }
        check(calls.n == 1 && r2s.endpoint == .sessionExpired("HTTP 401"), "coordinator: no second remote call inside the backoff window")
        _ = block { await c2.refresh(now: t1.addingTimeInterval(31)) }
        check(calls.n == 2, "coordinator: remote retried after backoff (30s)")
        _ = block { await c2.refresh(now: t1.addingTimeInterval(40)) }
        check(calls.n == 2, "coordinator: backoff doubles after repeated failures (next gap 60s)")
        endpoint.transport = { calls.n += 1; return goodLive }
        _ = block { await c2.refresh(now: t1.addingTimeInterval(100)) }
        let r5s = block { await c2.refresh(now: t1.addingTimeInterval(110), force: true) }
        if case .active = r5s.endpoint { check(r5s.status == .ok(.usageEndpoint) && r5s.snapshot?.fiveHour?.usedPercent == 42, "coordinator: C active becomes the primary source") }
        else { check(false, "coordinator: C active becomes the primary source") }
        check(r5s.throttleNote != nil, "coordinator: manual refresh inside 30s reports the throttle")
        let off1 = UsageEndpointProvider(isEnabled: false) { good }
        let c3 = UpdateCoordinator(entries: [.init(off1, minInterval: 30, isRemote: true), .init(StatuslineProvider(url: bFile))],
                                   logIndex: LogIndex(roots: [cTmp]), history: MemoryHistoryStore(), pricing: pricing)
        check(block { await c3.refresh() }.endpoint == .off, "coordinator: C off by default")
        let compared = Counter()
        c2.onCompare = { _ in compared.n += 1 }
        try? FileManager.default.removeItem(at: cTmp)

        // projection states
        let c4 = UpdateCoordinator(entries: [.init(StatuslineProvider(url: URL(fileURLWithPath: "/nonexistent")))],
                                   logIndex: LogIndex(roots: []), history: MemoryHistoryStore(), pricing: pricing)
        check({ if case .error = block({ await c4.refresh() }).status { return true }; return false }(), "coordinator: missing state and no logs = visible error")

        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let hm = Insights.heatmap(recs, calendar: cal)
        check(hm[4][10] == 1 && hm[4][16] == 1, "heatmap: Thursday 10h and 16h")
        let csv = Insights.csv(Aggregation.sessions(from: recs, pricing: pricing))
        check(csv.split(separator: "\n").count == 2 && csv.hasPrefix("session_id,"), "csv export: header + one session")

        // Coordinator end-to-end with a temp state.json and an empty log root.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let stateURL = tmp.appendingPathComponent("state.json")
        let nowEpoch = Int(Date().timeIntervalSince1970)
        try Data("{\"updated_at\":\(nowEpoch),\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":\(nowEpoch + 3600)}}}".utf8).write(to: stateURL)
        let coord = UpdateCoordinator(entries: [.init(UsageEndpointProvider { Data() }), .init(StatuslineProvider(url: stateURL))],
                                      logIndex: LogIndex(roots: [tmp]), history: MemoryHistoryStore(), pricing: pricing)
        final class StateBox: @unchecked Sendable { var s: MeterState? }
        let sb = StateBox(); let sem2 = DispatchSemaphore(value: 0)
        Task { sb.s = await coord.refresh(); sem2.signal() }
        sem2.wait()
        check(sb.s?.status == .ok(.statusLine) && sb.s?.snapshot?.fiveHour?.usedPercent == 42, "coordinator: disabled endpoint skipped, statusLine used")
        try Data("{\"updated_at\":\(nowEpoch - 4000),\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":\(nowEpoch + 3600)}}}".utf8).write(to: stateURL)
        let sb2 = StateBox(); let sem3 = DispatchSemaphore(value: 0)
        Task { sb2.s = await coord.refresh(); sem3.signal() }
        sem3.wait()
        if case .stale = sb2.s?.status { check(true, "coordinator: old state.json is flagged stale") } else { check(false, "coordinator: old state.json is flagged stale") }
        try? FileManager.default.removeItem(at: tmp)



        // chunked reading: a >1 MB file (lines straddle chunk edges) and a partial last line completed later
        let big = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: big.appendingPathComponent("-p"), withIntermediateDirectories: true)
        let bigFile = big.appendingPathComponent("-p/s.jsonl")
        var bigText = ""
        for i in 0..<3000 {
            bigText += String(decoding: line(msg: "b\(i)", req: "r\(i)", ts: "2026-10-29T10:00:00.000Z", out: i), as: UTF8.self)
                .replacingOccurrences(of: "\"cwd\":", with: "\"pad\":\"" + String(repeating: "x", count: 600) + "\",\"cwd\":") + "\n"
        }
        try bigText.write(to: bigFile, atomically: true, encoding: .utf8)
        check((try? Data(contentsOf: bigFile).count) ?? 0 > 2_000_000, "chunk test fixture is larger than 2 chunks")
        let bidx = LogIndex(roots: [big]); bidx.refresh()
        check(bidx.records.count == 3000, "chunked read: all lines parsed across chunk boundaries")
        let tail = String(decoding: line(msg: "late", req: "rl", ts: "2026-10-29T10:00:00.000Z", out: 1), as: UTF8.self)
        let fh = try FileHandle(forWritingTo: bigFile); fh.seekToEndOfFile()
        fh.write(Data(tail.prefix(40).utf8)); try fh.close()
        bidx.refresh()
        check(bidx.records.count == 3000, "chunked read: partial last line is not consumed")
        let fh2 = try FileHandle(forWritingTo: bigFile); fh2.seekToEndOfFile()
        fh2.write(Data((String(tail.dropFirst(40)) + "\n").utf8)); try fh2.close()
        bidx.refresh()
        check(bidx.records.count == 3001, "chunked read: line is parsed once it is complete")
        try? FileManager.default.removeItem(at: big)


        // --- weekly projection: 24h average (or since reset), only alerts before the reset, not on a young window ---
        let wnow = Date(timeIntervalSince1970: 1_800_000_000), day: TimeInterval = 86_400
        func wwin(elapsed: TimeInterval, used: Double) -> LimitWindow {
            LimitWindow(kind: .sevenDay, usedPercent: used, resetsAt: wnow.addingTimeInterval(7 * day - elapsed))
        }
        func wsample(_ ago: TimeInterval, _ pct: Double, _ w: LimitWindow) -> HistorySample {
            HistorySample(ts: wnow.addingTimeInterval(-ago), kind: .sevenDay, percent: pct, resetsAt: w.resetsAt)
        }
        if case .tooEarly = Insights.weeklyProjection(samples: [], current: wwin(elapsed: 3 * 3600, used: 10), now: wnow) {
            check(true, "weekly: 10% after 3h is 'too early', no exhaustion alert")
        } else { check(false, "weekly: 10% after 3h is 'too early', no exhaustion alert") }
        let w3 = wwin(elapsed: 3 * day, used: 10)
        if case .ready(let p) = Insights.weeklyProjection(samples: [wsample(25 * 3600, 9, w3)], current: w3, now: wnow) {
            check(p.exhaustsAt == nil && p.ratePerHour < 0.1, "weekly: slow 24h pace never alerts (1 point in 25h)")
        } else { check(false, "weekly: slow 24h pace never alerts") }
        let w3b = wwin(elapsed: 3 * day, used: 40)
        if case .ready(let p) = Insights.weeklyProjection(samples: [wsample(25 * 3600, 10, w3b), wsample(2 * 3600, 38, w3b)], current: w3b, now: wnow) {
            check(near(p.ratePerHour, 30.0 / 25.0, 1e-9) && p.exhaustsAt != nil, "weekly: baseline is the last sample at or before now-24h (1.2 pts/h), alerts when ETA < reset")
        } else { check(false, "weekly: baseline sample and alert") }
        let w20 = wwin(elapsed: 20 * 3600, used: 20)
        if case .ready(let p) = Insights.weeklyProjection(samples: [], current: w20, now: wnow) {
            check(near(p.ratePerHour, 1.0, 1e-9), "weekly: window younger than 24h averages since the reset (20% / 20h)")
        } else { check(false, "weekly: since-reset average") }

        // --- source switching without restart ---
        let sTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sTmp, withIntermediateDirectories: true)
        let sB = sTmp.appendingPathComponent("state.json"); let ne = Int(Date().timeIntervalSince1970)
        try Data("{\"updated_at\":\(ne),\"rate_limits\":{\"five_hour\":{\"used_percentage\":30,\"resets_at\":\(ne + 3600)},\"seven_day\":{\"used_percentage\":5,\"resets_at\":\(ne + 86400)}}}".utf8).write(to: sB)
        let sc = Counter()
        let sEnd = UsageEndpointProvider(isEnabled: false) { sc.n += 1; throw ProviderError.sessionExpired("HTTP 403") }
        let sCo = UpdateCoordinator(entries: [.init(sEnd, minInterval: 30, isRemote: true), .init(StatuslineProvider(url: sB))],
                                    logIndex: LogIndex(roots: [sTmp]), history: MemoryHistoryStore(), pricing: pricing)
        let s0 = Date()
        check(block { await sCo.refresh(now: s0) }.status == .ok(.statusLine), "switch: starts on B with C off")
        sEnd.isEnabled = true                                  // user turns C on, but is not logged in yet
        _ = block { await sCo.refresh(now: s0.addingTimeInterval(1), force: true) }
        _ = block { await sCo.refresh(now: s0.addingTimeInterval(40), force: true) }
        _ = block { await sCo.refresh(now: s0.addingTimeInterval(80), force: true) }   // failures pile up: backoff would be minutes
        let before = sc.n
        sEnd.transport = { sc.n += 1; return goodLive }            // user finishes the login
        sCo.resetRemote()
        let t4 = block { await sCo.refresh(now: s0.addingTimeInterval(115), force: true) }
        if case .active = t4.endpoint { check(sc.n == before + 1 && t4.status == .ok(.usageEndpoint) && t4.snapshot?.fiveHour?.usedPercent == 42,
                                             "switch: after login, C is queried at once and becomes the active source (despite earlier backoff)") }
        else { check(false, "switch: after login, C is queried at once and becomes the active source") }
        let t5 = block { await sCo.refresh(now: s0.addingTimeInterval(120), force: true) }
        check(t5.throttleNote != nil && (t5.throttleRetryAfter ?? 0) > 20 && sc.n == before + 1, "switch: a refresh 5s after a remote call waits (30s minimum) and says for how long")
        sEnd.isEnabled = false                                 // user turns C off
        let t6 = block { await sCo.refresh(now: s0.addingTimeInterval(125)) }
        check(t6.endpoint == .off && t6.status == .ok(.statusLine) && t6.snapshot?.fiveHour?.usedPercent == 30, "switch: turning C off returns to B immediately")
        try? FileManager.default.removeItem(at: sTmp)

        // --- project resolution / log roots ---
        let rs = ProjectResolver()
        check(rs.project(for: "/Users/x/projects/demo-app/.claude/worktrees/some-worktree") == "demo-app", "project: worktree path resolves to main repo")
        check(rs.project(for: "/sessions/wonderful-keen-cray") == ProjectResolver.coworkLabel, "project: desktop sandbox cwd")
        check(rs.project(for: "/Users/x/Library/Application Support/Claude/local-agent-mode-sessions/a/b/local_c/outputs") == ProjectResolver.coworkLabel, "project: desktop outputs dir")
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm-repo-\(UUID().uuidString)")
        let sub = repo.appendingPathComponent("spikes/latencia")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        check(rs.project(for: sub.path) == repo.lastPathComponent, "project: subfolder resolves to repo root via .git")
        let wt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/feature\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        check(rs.project(for: wt.path) == repo.lastPathComponent, "project: linked worktree (.git file) resolves to main repo")
        try? FileManager.default.removeItem(at: repo); try? FileManager.default.removeItem(at: wt)

        func mkroot(_ name: String, lines: [Data]) throws -> URL {
            let r = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm-root-\(UUID().uuidString)/\(name)")
            try FileManager.default.createDirectory(at: r.appendingPathComponent("-p"), withIntermediateDirectories: true)
            try (lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n")
                .write(to: r.appendingPathComponent("-p/s.jsonl"), atomically: true, encoding: .utf8)
            return r
        }
        let shared = line(msg: "dup", req: "r", ts: "2026-10-29T10:00:00.000Z", out: 5)
        let synthetic = Data(String(decoding: line(msg: "syn", req: "r2", ts: "2026-10-29T10:00:00.000Z", out: 0), as: UTF8.self)
            .replacingOccurrences(of: "claude-opus-5-5", with: "<synthetic>").utf8)
        let noReq = Data(String(decoding: line(msg: "nr", req: "x", ts: "2026-10-29T10:00:00.000Z", out: 7), as: UTF8.self)
            .replacingOccurrences(of: "\"requestId\":\"x\",", with: "").utf8)
        let r1 = try mkroot("a", lines: [shared, synthetic]), r2 = try mkroot("b", lines: [shared, noReq])
        let idx = LogIndex(roots: [r1, r2]); idx.refresh()
        check(idx.records.count == 2, "log index: two roots, shared response counted once, <synthetic> skipped, missing requestId kept")
        idx.refresh()
        check(idx.records.count == 2, "log index: second refresh reads nothing new")
        try? FileManager.default.removeItem(at: r1.deletingLastPathComponent()); try? FileManager.default.removeItem(at: r2.deletingLastPathComponent())
        // --- source C: resets_at null = window not started; per-window degradation ---
        let fiveNull = #"{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":{"utilization":10.0,"resets_at":"2026-11-05T08:59:59.5+00:00"},"spend":{"used":{"amount_minor":4250,"currency":"USD","exponent":2}}}"#
        let sn = try? UsageEndpointDecoder.decodeStrict(Data(fiveNull.utf8))
        check(sn != nil && sn!.fiveHour == nil && sn!.notStarted == [.fiveHour] && sn!.sevenDay?.usedPercent == 10 && near(sn!.extraUsage?.used, 42.50),
              "strict decoder: five_hour.resets_at null = window not started, 7d and spend kept (no endpoint change)")
        let badType = try? UsageEndpointDecoder.decodeStrict(Data(#"{"five_hour":{"utilization":5,"resets_at":123},"seven_day":{"utilization":10.0,"resets_at":"2026-11-05T08:59:59.5+00:00"}}"#.utf8))
        check(badType?.sevenDay != nil && badType?.fiveHour == nil && badType?.degraded[.fiveHour]?.contains("five_hour.resets_at número") == true,
              "strict decoder: one window of another type degrades only that window and names the field")
        check(UsageEndpointDecoder.decodeStrict(missingMsg: #"{"five_hour":{"utilization":null,"resets_at":"2026-11-05T08:59:59.5+00:00"},"seven_day":null}"#)?.contains("nulo") == true,
              "strict decoder: both windows unusable = endpoint changed, message says null")
        check(rejects("[1,2]"), "strict decoder: non-object JSON = endpoint changed")

        let fillDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fillDir, withIntermediateDirectories: true)
        let fillB = fillDir.appendingPathComponent("state.json"); let fe = Int(Date().timeIntervalSince1970)
        try Data("{\"updated_at\":\(fe),\"rate_limits\":{\"five_hour\":{\"used_percentage\":30,\"resets_at\":\(fe + 3600)}}}".utf8).write(to: fillB)
        let fillBody = Data(#"{"five_hour":{"utilization":5,"resets_at":123},"seven_day":{"utilization":10.0,"resets_at":"\#(fresh)"}}"#.utf8)
        let fillCo = UpdateCoordinator(entries: [.init(UsageEndpointProvider(isEnabled: true) { fillBody }, minInterval: 30, isRemote: true), .init(StatuslineProvider(url: fillB))],
                                       logIndex: LogIndex(roots: [fillDir]), history: MemoryHistoryStore(), pricing: pricing)
        let fillSt = block { await fillCo.refresh(now: Date()) }
        if case .active = fillSt.endpoint {
            check(fillSt.snapshot?.source == .usageEndpoint && fillSt.snapshot?.fiveHour?.usedPercent == 30 && fillSt.snapshot?.sevenDay?.usedPercent == 10
                  && fillSt.filledFromB == [.fiveHour], "coordinator: invalid C window filled from B, rest of C kept, C stays active")
        } else { check(false, "coordinator: invalid C window filled from B, rest of C kept, C stays active") }

        try? FileManager.default.removeItem(at: fillDir)

        // --- origins, session titles, product breakdown ---
        let bd = try? UsageEndpointDecoder.decodeStrict(good)
        check(bd?.breakdown.count == 4 && bd?.breakdown.first(where: { $0.key == "cowork" })?.percent == 65 && bd?.breakdown.first(where: { $0.key == "claude_code" })?.name == "Claude Code",
              "decoder: seven_day_breakdown rows (claude_code, chat, cowork, other) from the example sample")
        let metaBase = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm-meta-\(UUID().uuidString)")
        let coDir = metaBase.appendingPathComponent("local-agent-mode-sessions/a/b"), dcDir = metaBase.appendingPathComponent("claude-code-sessions/a/b")
        for d in [coDir, dcDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(#"{"cliSessionId":"cw1","title":"Resumo semanal","prompt":"NEVER READ"}"#.utf8).write(to: coDir.appendingPathComponent("local_1.json"))
        try Data(#"{"cliSessionId":"dc1","title":"Plano da fase 2"}"#.utf8).write(to: dcDir.appendingPathComponent("local_2.json"))
        try Data(#"{"title":"sem id"}"#.utf8).write(to: dcDir.appendingPathComponent("local_3.json"))
        let metaMap = SessionMetadata(base: metaBase).snapshot()
        check(metaMap.count == 2 && metaMap["cw1"] == SessionMeta(title: "Resumo semanal", origin: .cowork) && metaMap["dc1"]?.origin == .codeDesktop,
              "session metadata: title + origin by cliSessionId; files without cliSessionId ignored")
        func orec(_ sid: String, _ o: SessionOrigin) -> UsageRecord {
            var r = UsageRecord(sessionId: sid, messageId: "m-" + sid, requestId: "r", timestamp: Date(), cwd: nil, model: "claude-opus-5-5", usage: TokenUsage(input: 1))
            r.origin = o; return r
        }
        let recsO = [orec("cw1", .cowork), orec("dc1", .code), orec("cli1", .code)]
        let ors = Aggregation.origins(of: recsO, meta: metaMap)
        check(ors["cw1"] == .cowork && ors["dc1"] == .codeDesktop && ors["cli1"] == .code, "origins: Cowork by sandbox root, Code (app) by desktop metadata, CLI otherwise")
        let ss2 = Aggregation.sessions(from: recsO, pricing: pricing, meta: metaMap)
        check(ss2.first(where: { $0.id == "cw1" })?.title == "Resumo semanal" && ss2.first(where: { $0.id == "cli1" })?.title == nil, "sessions carry the desktop title; CLI sessions have none")
        let cwRoot = metaBase.appendingPathComponent("local-agent-mode-sessions/a/b/local_x/.claude/projects/-sessions-x")
        try FileManager.default.createDirectory(at: cwRoot, withIntermediateDirectories: true)
        try (line(session: "cwx", msg: "mq", req: "rq", ts: "2026-10-29T10:00:00.000Z", out: 5) + Data("\n".utf8)).write(to: cwRoot.appendingPathComponent("s.jsonl"))
        let oIdx = LogIndex(roots: [cwRoot.deletingLastPathComponent()]); oIdx.refresh()
        check(oIdx.records.first?.origin == .cowork, "log index: records under local-agent-mode-sessions are tagged Cowork")
        try? FileManager.default.removeItem(at: metaBase)

        // --- endpoint URLs entered by the user; demo data ---
        let okURL = "https://claude.ai/api/organizations/00000000-0000-4000-8000-000000000000/usage"
        check(EndpointURL.validate(okURL) != nil && EndpointURL.validate(" " + okURL + "\n") != nil, "endpoint URL: https claude.ai /api/organizations/… accepted (whitespace trimmed)")
        check(["http://claude.ai/api/organizations/x/usage", "https://claude.ai.evil.example/api/organizations/x/usage", "https://evil.example/api/organizations/x/usage",
               "https://user@claude.ai/api/organizations/x/usage", "https://claude.ai/other/usage", "https://claude.ai/api/organizations/", "not a url"].allSatisfy { EndpointURL.validate($0) == nil },
              "endpoint URL: wrong scheme, host, userinfo or path rejected")
        check(EndpointURL.validate(okURL).flatMap(EndpointURL.derivedCreditsURL(fromUsage:))?.absoluteString == "https://claude.ai/api/organizations/00000000-0000-4000-8000-000000000000/prepaid/credits",
              "endpoint URL: credits URL derived from the usage URL")
        let demo = DemoData.make(pricing: pricing, now: Date(timeIntervalSince1970: 1_800_000_000))
        check(demo.state.snapshot?.fiveHour?.usedPercent == 64 && !demo.state.sessions.isEmpty && demo.credits.balance?.amount == 25
              && Set(demo.state.sessions.map(\.origin)).count == 3 && demo.state.records.allSatisfy { ($0.cwd ?? "").hasPrefix("/Users/demo/") || $0.cwd == "/sessions/demo" },
              "demo data: synthetic limits, balance, sessions of all three origins, fictional paths only")

        // --- support directory migration (pre-rename folder -> YACW) ---
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yacw-home-\(UUID().uuidString)")
        let oldDir = home.appendingPathComponent("Library/Application Support/" + ["Claude", "Meter"].joined())
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: oldDir.appendingPathComponent("state.json"))
        try Data("hist".utf8).write(to: oldDir.appendingPathComponent("history.sqlite"))
        let newDir = AppPaths.supportDirectory(home: home)
        check(FileManager.default.contents(atPath: newDir.appendingPathComponent("history.sqlite").path) == Data("hist".utf8)
              && !FileManager.default.fileExists(atPath: oldDir.path), "migration: old support folder renamed to YACW with its files")
        let home2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yacw-home-\(UUID().uuidString)")
        let old2 = home2.appendingPathComponent("Library/Application Support/" + ["Claude", "Meter"].joined()), new2 = home2.appendingPathComponent("Library/Application Support/YACW")
        try FileManager.default.createDirectory(at: old2, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: new2, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old2.appendingPathComponent("state.json")); try Data("hist".utf8).write(to: old2.appendingPathComponent("history.sqlite"))
        try Data("new".utf8).write(to: new2.appendingPathComponent("state.json"))
        _ = AppPaths.supportDirectory(home: home2)
        check(FileManager.default.contents(atPath: new2.appendingPathComponent("state.json").path) == Data("new".utf8)
              && FileManager.default.fileExists(atPath: new2.appendingPathComponent("history.sqlite").path), "migration: both folders exist -> missing files moved, nothing overwritten")
        try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: home2)

        // --- credits balance (source C, second call) ---
        let creditsSample = try Data(contentsOf: sampleDir.appendingPathComponent("credits-response.example.json"))
        let cb = try? CreditsDecoder.decodeStrict(creditsSample)
        check(near(cb?.amount, 25.00) && cb?.currency == "USD", "credits decoder: amount_minor 2500 / exponent 2 / USD = 25.00")
        func creditsRejects(_ json: String) -> Bool {
            do { _ = try CreditsDecoder.decodeStrict(Data(json.utf8)); return false }
            catch { if case ProviderError.endpointChanged = error { return true }; return false }
        }
        check(creditsRejects(#"{"amount":2500}"#), "credits decoder: missing balance.money = endpoint changed")
        check(creditsRejects(#"{"balance":{"money":{"amount_minor":"2500","currency":"USD","exponent":2}}}"#), "credits decoder: non-numeric amount = endpoint changed")
        check(creditsRejects(#"{"balance":{"money":{"amount_minor":2500,"currency":"USD"}}}"#), "credits decoder: missing exponent = endpoint changed")
        let cCalls = GBox<Int>(); cCalls.v = 0
        let okBody = GBox<Bool>(); okBody.v = true
        let svc = CreditsService { cCalls.v! += 1; if okBody.v! { return creditsSample }; throw ProviderError.offline }
        let ct0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = block { await svc.refresh(force: false, now: ct0) }
        _ = block { await svc.refresh(force: false, now: ct0.addingTimeInterval(120)) }
        check(cCalls.v == 1, "credits service: no second call within 5 min unless forced")
        _ = block { await svc.refresh(force: true, now: ct0.addingTimeInterval(10)) }
        check(cCalls.v == 1, "credits service: forced call still respects the 30 s minimum")
        okBody.v = false
        let failed = block { await svc.refresh(force: true, now: ct0.addingTimeInterval(60)) }
        check(cCalls.v == 2 && failed.failure == ProviderError.offline && near(failed.balance?.amount, 25.00) && failed.balance?.fetchedAt == ct0,
              "credits service: failure keeps the last balance and its timestamp")
        okBody.v = true
        let credBack = block { await svc.refresh(force: false, now: ct0.addingTimeInterval(400)) }
        check(credBack.failure == nil && credBack.balance?.fetchedAt == ct0.addingTimeInterval(400), "credits service: recovers after 5 min")
        print(failures == 0 ? "\nselftest: all passed" : "\nselftest: \(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}

extension UsageEndpointDecoder {
    /// Test helper: the endpointChanged message for a body, nil when it decodes.
    static func decodeStrict(missingMsg json: String) -> String? {
        do { _ = try decodeStrict(Data(json.utf8)); return nil }
        catch ProviderError.endpointChanged(let m) { return m } catch { return nil }
    }
}

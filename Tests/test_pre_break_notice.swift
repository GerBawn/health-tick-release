#!/usr/bin/env swift
import Foundation

// Replicates AppState.maybeFirePreBreakNotice (issue #34): the pre-break
// heads-up fires exactly when the work countdown CROSSES the configured lead
// threshold, at most once per work session.

var testCount = 0
var passCount = 0
var failCount = 0

func assertEqual(_ actual: Int, _ expected: Int, _ msg: String, line: Int = #line) {
    testCount += 1
    if actual == expected {
        passCount += 1
        print("  PASS: \(msg)")
    } else {
        failCount += 1
        print("  FAIL: \(msg) -- expected \(expected), got \(actual) (line \(line))")
    }
}

// MARK: - Logic under test (mirror of AppState)

struct NoticeSim {
    var enabled: Bool
    var lead: Int
    var fired = false
    var fireCount = 0
    var lastFiredAt: Int = -1

    mutating func tick(oldVal: Int, newVal: Int) {
        guard enabled, !fired else { return }
        guard lead > 0, oldVal > lead, newVal <= lead, newVal > 0 else { return }
        fired = true
        fireCount += 1
        lastFiredAt = newVal
    }

    /// Run a full countdown from `total` down to 0 in 1s ticks.
    mutating func runCountdown(from total: Int) {
        var remaining = total
        while remaining > 0 {
            let old = remaining
            remaining -= 1
            tick(oldVal: old, newVal: remaining)
        }
    }
}

// MARK: - Tests

print("=== Normal crossing ===")
var s = NoticeSim(enabled: true, lead: 60)
s.runCountdown(from: 300)
assertEqual(s.fireCount, 1, "fires exactly once over a full countdown")
assertEqual(s.lastFiredAt, 60, "fires at the lead threshold")

print("=== Lead >= work duration ===")
s = NoticeSim(enabled: true, lead: 300)
s.runCountdown(from: 300)
assertEqual(s.fireCount, 0, "never fires when lead covers the whole session (no crossing)")

s = NoticeSim(enabled: true, lead: 400)
s.runCountdown(from: 300)
assertEqual(s.fireCount, 0, "never fires when lead exceeds the whole session")

print("=== Session restored below threshold ===")
s = NoticeSim(enabled: true, lead: 60)
s.runCountdown(from: 45)  // e.g. app relaunched with 45s left
assertEqual(s.fireCount, 0, "no announcement when restored already inside the lead window")

print("=== Clock jump (system sleep) ===")
s = NoticeSim(enabled: true, lead: 60)
s.tick(oldVal: 3000, newVal: 12)
assertEqual(s.fireCount, 1, "a jump across the threshold still fires")
assertEqual(s.lastFiredAt, 12, "fires with the actual remaining seconds")

s = NoticeSim(enabled: true, lead: 60)
s.tick(oldVal: 3000, newVal: 0)
assertEqual(s.fireCount, 0, "a jump straight to 0 skips the heads-up (real alert shows same tick)")

print("=== Disabled / already fired ===")
s = NoticeSim(enabled: false, lead: 60)
s.runCountdown(from: 300)
assertEqual(s.fireCount, 0, "disabled never fires")

s = NoticeSim(enabled: true, lead: 60)
s.fired = true
s.runCountdown(from: 300)
assertEqual(s.fireCount, 0, "already-fired flag suppresses refire")

print("=== Zero lead ===")
s = NoticeSim(enabled: true, lead: 0)
s.runCountdown(from: 300)
assertEqual(s.fireCount, 0, "lead 0 never fires")

print("============================")
print("Total: \(testCount), Passed: \(passCount), Failed: \(failCount)")
if failCount == 0 {
    print("ALL TESTS PASSED!")
} else {
    exit(1)
}

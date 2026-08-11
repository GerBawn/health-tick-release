#!/usr/bin/env swift
import Foundation

// Replicates AppState's snooze state machine (issue #35): the alert's third
// exit re-arms a short countdown in the .working phase without booking a
// skipped break, persists as "alerting" (a relaunch re-alerts instead of
// opening a phantom short work session), and reports full session minutes
// while the snooze runs.

var testCount = 0
var passCount = 0
var failCount = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ msg: String, line: Int = #line) {
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

enum Phase { case working, alerting, breaking, waiting, paused }

struct SnoozeSim {
    var phase: Phase = .working
    var snoozeActive = false
    var remainingSeconds = 0
    var workConfigMinutes = 45
    var skipCount = 0
    var breakConfirm = true

    // Mirror of snoozeBreakFromAlert
    mutating func snooze(minutes: Int) {
        guard phase == .alerting else { return }
        snoozeActive = true
        phase = .working
        remainingSeconds = minutes * 60
    }

    // Mirror of skipBreakFromAlert (the exit snooze must NOT resemble)
    mutating func skip() {
        guard phase == .alerting else { return }
        skipCount += 1
        startWork()
    }

    // Mirror of onWorkDone
    mutating func workDone() {
        snoozeActive = false
        if breakConfirm {
            phase = .alerting
            remainingSeconds = 0
        } else {
            phase = .breaking
        }
    }

    // Mirror of startWork
    mutating func startWork() {
        snoozeActive = false
        phase = .working
        remainingSeconds = workConfigMinutes * 60
    }

    // Mirror of saveTimerState's phase persistence choice
    var persistedPhase: String {
        switch phase {
        case .working: return snoozeActive ? "alerting" : "working"
        case .paused: return "paused"
        case .alerting, .breaking, .waiting: return "alerting"
        }
    }

    // Mirror of currentSessionWorkMinutes (working branch)
    var sessionWorkMinutes: Int {
        if snoozeActive { return workConfigMinutes }
        if phase == .working {
            return max(0, workConfigMinutes * 60 - remainingSeconds) / 60
        }
        return 0
    }
}

// MARK: - Tests

print("Test 1: snooze from alerting re-arms a short working countdown")
var sim = SnoozeSim()
sim.startWork()
sim.remainingSeconds = 0
sim.workDone()
assertEqual(sim.phase == .alerting, true, "alert fires when work is done")
sim.snooze(minutes: 5)
assertEqual(sim.phase == .working, true, "snooze returns to working phase")
assertEqual(sim.remainingSeconds, 300, "countdown re-armed to 5 minutes")
assertEqual(sim.snoozeActive, true, "snooze flag raised")
assertEqual(sim.skipCount, 0, "snooze does NOT count as a skip")

print("Test 2: snooze expiry re-alerts and clears the flag")
sim.remainingSeconds = 0
sim.workDone()
assertEqual(sim.phase == .alerting, true, "alert fires again after snooze")
assertEqual(sim.snoozeActive, false, "flag cleared on re-alert")
assertEqual(sim.skipCount, 0, "still no skip booked")

print("Test 3: repeated snooze is allowed, each from a fresh alert")
sim.snooze(minutes: 2)
assertEqual(sim.remainingSeconds, 120, "second snooze re-arms 2 minutes")
sim.workDone()
sim.snooze(minutes: 10)
assertEqual(sim.remainingSeconds, 600, "third snooze re-arms 10 minutes")
assertEqual(sim.skipCount, 0, "no skips across repeated snoozes")

print("Test 4: snooze outside alerting is a no-op")
var idle = SnoozeSim()
idle.startWork()
let before = idle.remainingSeconds
idle.snooze(minutes: 5)
assertEqual(idle.remainingSeconds, before, "working phase: countdown untouched")
assertEqual(idle.snoozeActive, false, "working phase: flag not raised")
idle.phase = .breaking
idle.snooze(minutes: 5)
assertEqual(idle.snoozeActive, false, "breaking phase: flag not raised")

print("Test 5: snooze persists as 'alerting' so a relaunch re-alerts")
var persist = SnoozeSim()
persist.startWork()
assertEqual(persist.persistedPhase, "working", "normal work persists as working")
persist.workDone()
persist.snooze(minutes: 5)
assertEqual(persist.persistedPhase, "alerting", "snoozed countdown persists as alerting")
persist.workDone()
persist.snooze(minutes: 5)
persist.startWork()  // e.g. a skip or reset while snoozing
assertEqual(persist.persistedPhase, "working", "startWork clears the snooze flag")

print("Test 6: session minutes stay at full config during snooze (no rollback)")
var mins = SnoozeSim()
mins.startWork()
mins.remainingSeconds = 0
assertEqual(mins.sessionWorkMinutes, 45, "work done: full 45 minutes")
mins.workDone()
mins.snooze(minutes: 5)
assertEqual(mins.sessionWorkMinutes, 45, "snoozing: still 45, not 40")
mins.remainingSeconds = 60
assertEqual(mins.sessionWorkMinutes, 45, "mid-snooze: still 45")

print("Test 7: skip still books a skip (snooze didn't change its path)")
var skipper = SnoozeSim()
skipper.startWork()
skipper.workDone()
skipper.skip()
assertEqual(skipper.skipCount, 1, "skip increments the count")
assertEqual(skipper.phase == .working, true, "skip restarts work")

print("")
print("\(passCount)/\(testCount) passed, \(failCount) failed")
exit(failCount == 0 ? 0 : 1)

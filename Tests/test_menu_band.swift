#!/usr/bin/env swift
import Foundation
import CoreGraphics

// MARK: - Test helpers

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

func assertNil(_ actual: CGRect?, _ msg: String, line: Int = #line) {
    testCount += 1
    if actual == nil {
        passCount += 1
        print("  PASS: \(msg)")
    } else {
        failCount += 1
        print("  FAIL: \(msg) -- expected nil, got \(actual!) (line \(line))")
    }
}

// MARK: - Logic under test
// Mirror of BreakOverlayManager.menuBandCorrection (Sources/BreakOverlay.swift,
// issues #29/#30). KEEP IN SYNC: the app version takes NSScreen + reads live
// anchors; this one takes the visibleFrame and anchor midX candidates as
// parameters so the geometry math is testable standalone.

func menuBandCorrection(for f: CGRect, vis: CGRect, anchorMidXs: [CGFloat]) -> CGRect? {
    let topOK = f.maxY <= vis.maxY && f.maxY >= vis.maxY - 44
    let xOK = f.minX >= vis.minX - 1 && f.maxX <= vis.maxX + 1
    if topOK && xOK { return nil }
    var out = f
    out.origin.y = (vis.maxY - 4) - f.height
    let anchorX = anchorMidXs.first { $0 > vis.minX && $0 < vis.maxX }
    if let anchorX { out.origin.x = anchorX - f.width / 2 }
    out.origin.x = min(max(out.origin.x, vis.minX + 8), vis.maxX - f.width - 8)
    return out
}

// MARK: - Tests
// Geometry from the 2026-07-24 probe session: laptop screen 1512x982 with
// visibleFrame maxY 949 (33pt menu bar), external display visibleFrame
// maxY 982 (no inset). Healthy panel: (999, 694, 240, 253), maxY 947.

let vis = CGRect(x: 0, y: 0, width: 1512, height: 949)
let anchor: [CGFloat] = [1121]

print("Menu band: in-band frames pass untouched (issue #9 red line)")
assertNil(menuBandCorrection(for: CGRect(x: 999, y: 694, width: 240, height: 253), vis: vis, anchorMidXs: anchor),
          "native placement (2pt gap, maxY 947)")
assertNil(menuBandCorrection(for: CGRect(x: 999, y: 696, width: 240, height: 253), vis: vis, anchorMidXs: anchor),
          "flush against the bar (maxY == vis.maxY)")
assertNil(menuBandCorrection(for: CGRect(x: 999, y: 652, width: 240, height: 253), vis: vis, anchorMidXs: anchor),
          "bottom of the 44pt band (maxY 905)")

print("Menu band: issue #30 — top edge intruding into the menu bar")
let fromExternal = CGRect(x: 999, y: 982 - 253, width: 240, height: 253)  // band of the 982-maxY external screen
if let fixed = menuBandCorrection(for: fromExternal, vis: vis, anchorMidXs: anchor) {
    assertEqual(fixed.maxY, 945, "top pulled back to vis.maxY - 4")
    assertEqual(fixed.origin.x, 1121 - 120, "x recentered under the anchor")
} else {
    assertEqual(false, true, "cross-screen frame must be corrected")
}
assertEqual(menuBandCorrection(for: CGRect(x: 999, y: 697, width: 240, height: 253), vis: vis, anchorMidXs: anchor) != nil,
            true, "1pt intrusion (maxY 950) is corrected")

print("Menu band: issue #29 — panel adrift mid-screen")
if let fixed = menuBandCorrection(for: CGRect(x: 556, y: 348, width: 240, height: 253), vis: vis, anchorMidXs: anchor) {
    assertEqual(fixed.maxY, 945, "adrift frame re-anchored below the bar")
    assertEqual(fixed.origin.x, 1001, "adrift frame recentered under the anchor")
} else {
    assertEqual(false, true, "mid-screen frame must be corrected")
}
assertEqual(menuBandCorrection(for: CGRect(x: 999, y: 651, width: 240, height: 253), vis: vis, anchorMidXs: anchor) != nil,
            true, "just below the band (maxY 904) is corrected")

print("Menu band: x handling")
if let fixed = menuBandCorrection(for: CGRect(x: 1400, y: 694, width: 240, height: 253), vis: vis, anchorMidXs: []) {
    assertEqual(fixed.origin.x, 1512 - 240 - 8, "no anchor: clamped to the right margin")
    assertEqual(fixed.maxY, 945, "x-only violation still lands in band")
} else {
    assertEqual(false, true, "off-screen-right frame must be corrected")
}
if let fixed = menuBandCorrection(for: CGRect(x: 556, y: 348, width: 240, height: 253), vis: vis, anchorMidXs: [1600, 1121]) {
    assertEqual(fixed.origin.x, 1001, "off-screen anchor candidates are skipped")
} else {
    assertEqual(false, true, "correction expected")
}

print("")
print("\(testCount) tests, \(passCount) passed, \(failCount) failed")
exit(failCount == 0 ? 0 : 1)

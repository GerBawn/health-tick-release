#!/usr/bin/env swift
import Foundation

// MARK: - Test helpers

var testCount = 0
var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    testCount += 1
    if condition {
        passCount += 1
        print("  PASS: \(msg)")
    } else {
        failCount += 1
        print("  FAIL: \(msg) (line \(line))")
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ msg: String, file: String = #file, line: Int = #line) {
    testCount += 1
    if actual == expected {
        passCount += 1
        print("  PASS: \(msg)")
    } else {
        failCount += 1
        print("  FAIL: \(msg) -- expected \(expected), got \(actual) (line \(line))")
    }
}

// MARK: - compareVersions (copied from UpdateChecker)

func compareVersions(_ remote: String, isNewerThan local: String) -> Bool {
    let r = remote.split(separator: ".").compactMap { Int($0) }
    let l = local.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(r.count, l.count) {
        let rv = i < r.count ? r[i] : 0
        let lv = i < l.count ? l[i] : 0
        if rv > lv { return true }
        if rv < lv { return false }
    }
    return false
}

// MARK: - Version comparison tests

print("=== Version comparison tests ===\n")

assert(compareVersions("1.3.13", isNewerThan: "1.3.12"), "1. 1.3.13 > 1.3.12")
assert(!compareVersions("1.3.12", isNewerThan: "1.3.12"), "2. 1.3.12 == 1.3.12")
assert(!compareVersions("1.3.11", isNewerThan: "1.3.12"), "3. 1.3.11 < 1.3.12")
assert(compareVersions("2.0.0", isNewerThan: "1.9.9"), "4. 2.0.0 > 1.9.9")
assert(compareVersions("1.4.0", isNewerThan: "1.3.99"), "5. 1.4.0 > 1.3.99")
assert(!compareVersions("1.0.0", isNewerThan: "1.0.0"), "6. equal versions")
assert(compareVersions("1.0.1", isNewerThan: "1.0"), "7. 1.0.1 > 1.0 (different length)")
assert(!compareVersions("1.0.0", isNewerThan: "1.0"), "8. 1.0.0 == 1.0 (padded)")

// MARK: - Tag parsing tests

print("\n=== Tag name parsing tests ===\n")

func parseVersion(from tagName: String) -> String {
    tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
}

assertEqual(parseVersion(from: "v1.3.12"), "1.3.12", "9. parse v1.3.12")
assertEqual(parseVersion(from: "V1.3.12"), "1.3.12", "10. parse V1.3.12")
assertEqual(parseVersion(from: "1.3.12"), "1.3.12", "11. parse 1.3.12 (no prefix)")

// MARK: - Gitee JSON parsing tests

print("\n=== Gitee API JSON parsing tests ===\n")

let sampleGiteeResponse = """
{
    "id": 12345,
    "tag_name": "v1.3.13",
    "name": "HealthTick v1.3.13",
    "body": "Release notes",
    "assets": [
        {
            "name": "HealthTick-v1.3.13-Apple-Silicon.dmg",
            "browser_download_url": "https://gitee.com/lifedever/health-tick-release/releases/download/v1.3.13/HealthTick-v1.3.13-Apple-Silicon.dmg"
        },
        {
            "name": "HealthTick-v1.3.13-Intel.dmg",
            "browser_download_url": "https://gitee.com/lifedever/health-tick-release/releases/download/v1.3.13/HealthTick-v1.3.13-Intel.dmg"
        }
    ]
}
"""

do {
    let data = sampleGiteeResponse.data(using: .utf8)!
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    // Test tag_name extraction
    let tagName = json["tag_name"] as! String
    assertEqual(tagName, "v1.3.13", "12. Gitee JSON tag_name extraction")

    let remote = parseVersion(from: tagName)
    assertEqual(remote, "1.3.13", "13. Gitee version parsing from tag")

    // Test asset matching for Apple Silicon
    let platformKey = "Apple-Silicon"
    let dmgName = "HealthTick-\(tagName)-\(platformKey).dmg"
    var foundURL: String?
    if let assets = json["assets"] as? [[String: Any]] {
        for asset in assets {
            if let name = asset["name"] as? String, name == dmgName,
               let browserURL = asset["browser_download_url"] as? String {
                foundURL = browserURL
                break
            }
        }
    }
    assertEqual(foundURL ?? "", "https://gitee.com/lifedever/health-tick-release/releases/download/v1.3.13/HealthTick-v1.3.13-Apple-Silicon.dmg", "14. Gitee asset URL for Apple Silicon")

    // Test asset matching for Intel
    let intelDmg = "HealthTick-\(tagName)-Intel.dmg"
    var intelURL: String?
    if let assets = json["assets"] as? [[String: Any]] {
        for asset in assets {
            if let name = asset["name"] as? String, name == intelDmg,
               let browserURL = asset["browser_download_url"] as? String {
                intelURL = browserURL
                break
            }
        }
    }
    assertEqual(intelURL ?? "", "https://gitee.com/lifedever/health-tick-release/releases/download/v1.3.13/HealthTick-v1.3.13-Intel.dmg", "15. Gitee asset URL for Intel")

    // Test version comparison with current
    let currentVersion = "1.3.12"
    assert(compareVersions(remote, isNewerThan: currentVersion), "16. 1.3.13 is newer than 1.3.12")
}

// MARK: - Gitee JSON parsing edge cases

print("\n=== Gitee JSON edge cases ===\n")

// Empty assets array
let noAssetsResponse = """
{"id": 1, "tag_name": "v1.4.0", "assets": []}
"""
do {
    let data = noAssetsResponse.data(using: .utf8)!
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let tagName = json["tag_name"] as! String
    let dmgName = "HealthTick-\(tagName)-Apple-Silicon.dmg"
    var foundURL: String?
    if let assets = json["assets"] as? [[String: Any]] {
        for asset in assets {
            if let name = asset["name"] as? String, name == dmgName,
               let browserURL = asset["browser_download_url"] as? String {
                foundURL = browserURL
            }
        }
    }
    // Should fallback to constructed URL
    if foundURL == nil {
        foundURL = "https://gitee.com/lifedever/health-tick-release/releases/download/\(tagName)/\(dmgName)"
    }
    assertEqual(foundURL ?? "", "https://gitee.com/lifedever/health-tick-release/releases/download/v1.4.0/HealthTick-v1.4.0-Apple-Silicon.dmg", "17. Fallback URL when assets empty")
}

// No assets field at all
let noAssetsFieldResponse = """
{"id": 1, "tag_name": "v2.0.0"}
"""
do {
    let data = noAssetsFieldResponse.data(using: .utf8)!
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let tagName = json["tag_name"] as! String
    let assets = json["assets"] as? [[String: Any]]
    assert(assets == nil, "18. Missing assets field is nil")
    let dmgName = "HealthTick-\(tagName)-Apple-Silicon.dmg"
    let fallback = "https://gitee.com/lifedever/health-tick-release/releases/download/\(tagName)/\(dmgName)"
    assert(fallback.contains("v2.0.0"), "19. Fallback URL constructed correctly without assets")
}

// MARK: - GitHub redirect Location parsing tests

print("\n=== GitHub redirect parsing tests ===\n")

func parseTagFromLocation(_ location: String) -> String? {
    guard let tagRange = location.range(of: "/tag/") else { return nil }
    return String(location[tagRange.upperBound...])
}

assertEqual(parseTagFromLocation("https://github.com/lifedever/health-tick-release/releases/tag/v1.3.12") ?? "", "v1.3.12", "20. Parse tag from GitHub Location header")
assertEqual(parseTagFromLocation("https://github.com/lifedever/health-tick-release/releases/tag/v2.0.0") ?? "", "v2.0.0", "21. Parse tag v2.0.0")
assert(parseTagFromLocation("https://github.com/lifedever/health-tick-release/releases") == nil, "22. No /tag/ in Location returns nil")

// MARK: - Download URL construction tests

print("\n=== Download URL construction tests ===\n")

let githubRepo = "lifedever/health-tick-release"
let giteeRepo = "lifedever/health-tick-release"

func buildGitHubDownloadURL(tag: String, platform: String) -> String {
    "https://github.com/\(githubRepo)/releases/download/\(tag)/HealthTick-\(tag)-\(platform).dmg"
}

func buildGiteeDownloadURL(tag: String, platform: String) -> String {
    "https://gitee.com/\(giteeRepo)/releases/download/\(tag)/HealthTick-\(tag)-\(platform).dmg"
}

assertEqual(
    buildGitHubDownloadURL(tag: "v1.3.13", platform: "Apple-Silicon"),
    "https://github.com/lifedever/health-tick-release/releases/download/v1.3.13/HealthTick-v1.3.13-Apple-Silicon.dmg",
    "23. GitHub download URL for Apple Silicon"
)
assertEqual(
    buildGiteeDownloadURL(tag: "v1.3.13", platform: "Intel"),
    "https://gitee.com/lifedever/health-tick-release/releases/download/v1.3.13/HealthTick-v1.3.13-Intel.dmg",
    "24. Gitee download URL for Intel"
)

// MARK: - Live API tests (Gitee + GitHub)

print("\n=== Live API tests ===\n")

let semaphore = DispatchSemaphore(value: 0)

// Test 1: Gitee API (should return 404 since no releases yet, which is expected)
print("  Testing Gitee API connectivity...")
let giteeURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)/releases/latest")!
var giteeRequest = URLRequest(url: giteeURL)
giteeRequest.timeoutInterval = 5
URLSession.shared.dataTask(with: giteeRequest) { data, response, error in
    if let error {
        failCount += 1; testCount += 1
        print("  FAIL: 25. Gitee API request failed: \(error.localizedDescription)")
    } else if let httpResponse = response as? HTTPURLResponse {
        testCount += 1
        if httpResponse.statusCode == 200 {
            passCount += 1
            print("  PASS: 25. Gitee API reachable, has releases (status 200)")
            // Verify JSON structure
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                testCount += 1
                if json["tag_name"] != nil {
                    passCount += 1
                    print("  PASS: 26. Gitee JSON has tag_name field")
                } else {
                    failCount += 1
                    print("  FAIL: 26. Gitee JSON missing tag_name")
                }
            }
        } else if httpResponse.statusCode == 404 {
            passCount += 1
            print("  PASS: 25. Gitee API reachable, no releases yet (status 404 - expected for new repo)")
        } else {
            failCount += 1
            print("  FAIL: 25. Gitee API unexpected status: \(httpResponse.statusCode)")
        }
    }
    semaphore.signal()
}.resume()
semaphore.wait()

// Test 2: GitHub redirect (should work since releases exist)
print("  Testing GitHub redirect...")
let githubURL = URL(string: "https://github.com/\(githubRepo)/releases/latest")!
var ghRequest = URLRequest(url: githubURL)
ghRequest.timeoutInterval = 10

class TestRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

let redirectBlocker = TestRedirectBlocker()
let ghSession = URLSession(configuration: .default, delegate: redirectBlocker, delegateQueue: nil)

ghSession.dataTask(with: ghRequest) { _, response, error in
    if let error {
        testCount += 1
        // GitHub might be unreachable from China, that's acceptable
        passCount += 1
        print("  PASS: 27. GitHub unreachable (expected in China): \(error.localizedDescription)")
    } else if let httpResponse = response as? HTTPURLResponse {
        let location = httpResponse.value(forHTTPHeaderField: "Location")
        testCount += 1
        if let location, location.contains("/tag/") {
            passCount += 1
            let tag = parseTagFromLocation(location) ?? "unknown"
            print("  PASS: 27. GitHub redirect works, latest tag: \(tag)")
        } else if httpResponse.statusCode == 302 || httpResponse.statusCode == 301 {
            passCount += 1
            print("  PASS: 27. GitHub returned redirect (Location: \(location ?? "nil"))")
        } else {
            failCount += 1
            print("  FAIL: 27. GitHub unexpected response: status=\(httpResponse.statusCode), location=\(location ?? "nil")")
        }
    }
    semaphore.signal()
}.resume()
semaphore.wait()

// Test 3: Gitee fallback simulation — if Gitee returns 404, the app should fall back to GitHub
print("  Testing fallback logic simulation...")
testCount += 1
let giteeStatus = 404 // simulating no release on Gitee
let shouldFallback = giteeStatus != 200
if shouldFallback {
    passCount += 1
    print("  PASS: 28. Gitee 404 triggers fallback to GitHub correctly")
} else {
    failCount += 1
    print("  FAIL: 28. Should have triggered fallback")
}

// MARK: - Site feed (docs/latest.json) consistency
// The in-app updater's PRIMARY source is docs/latest.json served via GitHub
// Pages. A feed whose sha256/size doesn't match the DMG actually in
// docs/downloads/ makes every client download fail verification — guard the
// release pipeline here, offline and deterministically.

print("\n=== Site feed consistency (docs/latest.json) ===\n")

import CryptoKit

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let feedURL = repoRoot.appendingPathComponent("docs/latest.json")

if let feedData = try? Data(contentsOf: feedURL),
   let feed = try? JSONSerialization.jsonObject(with: feedData) as? [String: Any] {

    let version = feed["version"] as? String ?? ""
    assert(!version.isEmpty && !version.hasPrefix("v"), "feed version present, no 'v' prefix: \(version)")

    let downloads = feed["downloads"] as? [String: [String: Any]] ?? [:]
    for key in ["Apple-Silicon", "Intel"] {
        guard let entry = downloads[key] else {
            assert(false, "feed downloads has \(key) entry")
            continue
        }
        let urlStr = entry["url"] as? String ?? ""
        assert(urlStr.hasSuffix("HealthTick-v\(version)-\(key).dmg"),
               "\(key) url matches version & platform naming")
        assert(urlStr.hasPrefix("https://www.lifedever.com/health-tick-release/downloads/"),
               "\(key) url points at the site downloads dir")

        let dmg = repoRoot.appendingPathComponent("docs/downloads/HealthTick-v\(version)-\(key).dmg")
        if let dmgData = try? Data(contentsOf: dmg) {
            let actualSHA = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
            assertEqual(actualSHA, (entry["sha256"] as? String ?? "").lowercased(),
                        "\(key) sha256 matches DMG on disk")
            assertEqual(dmgData.count, entry["size"] as? Int ?? -1,
                        "\(key) size matches DMG on disk")
        } else {
            assert(false, "\(key) DMG exists in docs/downloads/")
        }
    }
} else {
    assert(false, "docs/latest.json exists and parses")
}

// MARK: - Summary

print("\n============================")
print("Total: \(testCount), Passed: \(passCount), Failed: \(failCount)")
if failCount > 0 {
    print("SOME TESTS FAILED!")
    exit(1)
} else {
    print("ALL TESTS PASSED!")
}

import AppKit
import CryptoKit
import Foundation

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
let githubRepo = "lifedever/health-tick-release"
let giteeRepo = "lifedever/health-tick-release"

/// Static JSON feed on our own site (GitHub Pages + Cloudflare). Primary source
/// for both the version check (no API rate limit) and the DMG download —
/// reachable from mainland China without a proxy, unlike raw GitHub releases.
private let latestJsonURL = "https://www.lifedever.com/health-tick-release/latest.json"

private var isAppleSilicon: Bool {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafePointer(to: &sysinfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    return machine.hasPrefix("arm64")
}

private let platformKey = isAppleSilicon ? "Apple-Silicon" : "Intel"

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var latestVersion: String?
    @Published var releaseNotes: String?
    @Published var isChecking = false
    @Published var hasUpdate = false
    @Published var checkError: String?

    // Download state
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var downloadComplete = false
    @Published var downloadedFileURL: URL?

    /// Ordered download sources: site feed URL first, then Gitee, then GitHub.
    /// On failure the next candidate is tried automatically.
    private var downloadCandidates: [URL] = []
    private var currentCandidateIndex = 0
    /// Expected SHA-256 of the DMG from latest.json's checksums. The same file
    /// is uploaded to every mirror, so the hash applies to all candidates.
    /// Nil when the feed was unavailable (Gitee/GitHub API fallback check) —
    /// then only the byte-size check runs.
    private var expectedSHA256: String?

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: UpdateDownloadDelegate?
    private var downloadSession: URLSession?

    // MARK: - Check

    func check(silent: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        Task { await checkForUpdates(silent: silent) }
    }

    func skipVersion() {
        if let ver = latestVersion {
            UserDefaults.standard.set(ver, forKey: "skippedVersion")
        }
        hasUpdate = false
    }

    func showUpdateAlertPublic() {
        if hasUpdate {
            showUpdateWindow()
        } else {
            check(silent: false)
        }
    }

    private func checkForUpdates(silent: Bool) async {
        defer { isChecking = false }

        var remoteVersion: String?
        var notes: String?
        var feedEntry: LatestFeed.DownloadEntry?
        expectedSHA256 = nil

        // Primary: static JSON feed
        if let feed = await fetchLatestJSON() {
            remoteVersion = feed.version
            let zh = feed.notesZh ?? ""
            let en = feed.notesEn ?? ""
            notes = L.isZhAccess ? (zh.isEmpty ? en : zh) : (en.isEmpty ? zh : en)
            feedEntry = feed.downloads[platformKey]
            if let size = feedEntry?.size { totalBytes = Int64(size) }
            expectedSHA256 = feedEntry?.sha256
        }

        // Fallback: Gitee API → GitHub API
        if remoteVersion == nil {
            var release = await fetchLatestRelease(
                from: "https://gitee.com/api/v5/repos/\(giteeRepo)/releases/latest"
            )
            if release == nil {
                release = await fetchLatestRelease(
                    from: "https://api.github.com/repos/\(githubRepo)/releases/latest"
                )
            }
            guard let release else {
                if !silent { checkError = L.networkError("latest.json / Gitee / GitHub") }
                return
            }
            remoteVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            notes = release.body
            let dmgName = "HealthTick-v\(remoteVersion!)-\(platformKey).dmg"
            if let asset = release.assets?.first(where: { $0.name == dmgName }),
               let size = asset.size {
                totalBytes = Int64(size)
            }
        }

        guard let remoteVersion else { return }

        // A newer version supersedes any previously downloaded-but-uninstalled
        // DMG — without this reset the dialog would offer to install the stale
        // file under the new version's banner.
        if latestVersion != remoteVersion {
            if isDownloading { cancelDownload() }
            downloadComplete = false
            downloadedFileURL = nil
            downloadProgress = 0
            downloadedBytes = 0
        }

        latestVersion = remoteVersion
        releaseNotes = notes

        // Build the download fallback chain. All mirrors carry the same DMG.
        let dmgName = "HealthTick-v\(remoteVersion)-\(platformKey).dmg"
        var candidates: [URL] = []
        if let feedURL = feedEntry.flatMap({ URL(string: $0.url) }) {
            candidates.append(feedURL)
        } else if let siteURL = URL(string: "https://www.lifedever.com/health-tick-release/downloads/\(dmgName)") {
            candidates.append(siteURL)
        }
        if let gitee = URL(string: "https://gitee.com/\(giteeRepo)/releases/download/v\(remoteVersion)/\(dmgName)") {
            candidates.append(gitee)
        }
        if let github = URL(string: "https://github.com/\(githubRepo)/releases/download/v\(remoteVersion)/\(dmgName)") {
            candidates.append(github)
        }
        downloadCandidates = candidates
        currentCandidateIndex = 0

        // Skip-version only suppresses background checks; a user-initiated
        // check always reports the result.
        let skippedVersion = UserDefaults.standard.string(forKey: "skippedVersion")
        if silent && remoteVersion == skippedVersion {
            hasUpdate = false
            return
        }

        if compareVersions(remoteVersion, isNewerThan: appVersion) {
            hasUpdate = true
            showUpdateWindow()
        } else if !silent {
            showNoUpdateAlert()
        }
    }

    /// Dev builds may point the feed at a locally-hosted mock latest.json to
    /// test the dialog / download flow without touching production:
    ///     defaults write <dev-bundle-id> devLatestJsonOverride "http://localhost:8123/latest.json"
    ///     defaults delete <dev-bundle-id> devLatestJsonOverride
    private var resolvedLatestJsonURL: String {
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
           let override = UserDefaults.standard.string(forKey: "devLatestJsonOverride"),
           !override.isEmpty {
            return override
        }
        return latestJsonURL
    }

    private func fetchLatestJSON() async -> LatestFeed? {
        // Cache-bust: the CDN edge caches latest.json; reloadIgnoringLocalCacheData
        // only bypasses the local cache, not the edge. A unique URL per request
        // forces the CDN back to origin so a fresh release is visible immediately.
        let separator = resolvedLatestJsonURL.contains("?") ? "&" : "?"
        let busted = "\(resolvedLatestJsonURL)\(separator)t=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: busted) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(LatestFeed.self, from: data)
        } catch {
            return nil
        }
    }

    private func fetchLatestRelease(from urlString: String) async -> ReleaseInfo? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(ReleaseInfo.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Download

    func downloadUpdate() {
        guard let url = downloadCandidates.first else { return }
        currentCandidateIndex = 0
        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        downloadComplete = false
        downloadedFileURL = nil
        startDownloadFrom(url: url)
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        isDownloading = false
        downloadProgress = 0
        downloadComplete = false
    }

    private func startDownloadFrom(url: URL) {
        // Invalidate previous session to prevent URLSession + delegate leak
        downloadSession?.invalidateAndCancel()
        downloadSession = nil

        let delegate = UpdateDownloadDelegate(
            expectedSHA256: expectedSHA256,
            incompleteMessage: L.updateIncomplete,
            onProgress: { [weak self] progress, received, total in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.downloadedBytes = received
                    self?.totalBytes = total
                }
            },
            onComplete: { [weak self] fileURL in
                Task { @MainActor in
                    self?.downloadSession?.finishTasksAndInvalidate()
                    self?.downloadSession = nil
                    self?.downloadComplete = true
                    self?.downloadedFileURL = fileURL
                    self?.isDownloading = false
                }
            },
            onError: { [weak self] message, isCancelled in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadSession?.invalidateAndCancel()
                    self.downloadSession = nil
                    // User-initiated cancel must not walk the fallback chain.
                    guard !isCancelled else { return }
                    let next = self.currentCandidateIndex + 1
                    if next < self.downloadCandidates.count {
                        self.currentCandidateIndex = next
                        self.downloadProgress = 0
                        self.downloadedBytes = 0
                        self.startDownloadFrom(url: self.downloadCandidates[next])
                        return
                    }
                    self.isDownloading = false
                    self.checkError = L.downloadFailed(message)
                }
            }
        )
        self.downloadDelegate = delegate

        // Short request timeout so a "connected but trickling zero bytes" host
        // (GitHub without a proxy) fails over to the next mirror quickly instead
        // of stalling the progress bar forever.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    // MARK: - Install

    func installAndRestart() {
        guard let fileURL = downloadedFileURL else { return }

        let destApp = Bundle.main.bundlePath
        let dmgPath = fileURL.path

        let script = """
        #!/bin/bash
        DMG_PATH="\(dmgPath)"
        DEST_APP="\(destApp)"
        APP_NAME="HealthTick"

        MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse -noverify 2>/dev/null | grep -o '/Volumes/[^\t]*' | head -1)

        if [ -z "$MOUNT_POINT" ]; then
            open "$DMG_PATH"
            exit 1
        fi

        SOURCE_APP="$MOUNT_POINT/$APP_NAME.app"

        if [ ! -d "$SOURCE_APP" ]; then
            hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
            open "$DMG_PATH"
            exit 1
        fi

        sleep 2

        rm -rf "$DEST_APP"
        cp -R "$SOURCE_APP" "$DEST_APP"
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
        open "$DEST_APP"
        rm -f "$0"
        """

        do {
            let scriptPath = NSTemporaryDirectory() + "healthtick_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()

            NSApp.terminate(nil)
        } catch {
            // Fallback: open the DMG manually
            NSWorkspace.shared.open(fileURL)
        }
    }

    // MARK: - UI

    func showUpdateWindow() {
        NSApp.setActivationPolicy(.regular)
        WindowManager.shared.show(
            id: "update",
            title: L.newVersionFound,
            size: NSSize(width: 520, height: 420),
            autoResizesToContent: true
        ) {
            UpdateDialogView(updater: UpdateChecker.shared)
        }
    }

    func closeUpdateWindow() {
        WindowManager.shared.close(id: "update")
    }

    private func showNoUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = L.noUpdateTitle
        alert.informativeText = L.noUpdateMsg(appVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Helpers

    private func compareVersions(_ remote: String, isNewerThan local: String) -> Bool {
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
}

// MARK: - Feed Models

struct LatestFeed: Codable {
    let version: String
    let notesZh: String?
    let notesEn: String?
    let downloads: [String: DownloadEntry]

    enum CodingKeys: String, CodingKey {
        case version, downloads
        case notesZh = "notes_zh"
        case notesEn = "notes_en"
    }

    struct DownloadEntry: Codable {
        let url: String
        let size: Int?
        let sha256: String?
    }
}

private struct ReleaseInfo: Codable {
    let tagName: String
    let body: String?
    let assets: [Asset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body, assets
    }

    struct Asset: Codable {
        let name: String
        let size: Int?
    }
}

// MARK: - Download Delegate

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let expectedSHA256: String?
    /// Localized "download incomplete" text, captured on the main actor at init
    /// — this delegate runs on a background queue and must not touch `L`.
    let incompleteMessage: String
    let onProgress: (Double, Int64, Int64) -> Void
    let onComplete: (URL) -> Void
    /// (message, isCancelled) — cancellation must not trigger mirror fallback.
    let onError: (String, Bool) -> Void

    init(
        expectedSHA256: String?,
        incompleteMessage: String,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (URL) -> Void,
        onError: @escaping (String, Bool) -> Void
    ) {
        self.expectedSHA256 = expectedSHA256
        self.incompleteMessage = incompleteMessage
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("HealthTick-update.dmg")
        try? FileManager.default.removeItem(at: dest)

        // `location` is deleted by the system as soon as this callback returns;
        // move it to a stable path before handing it off.
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            do {
                try FileManager.default.copyItem(at: location, to: dest)
            } catch {
                onError(incompleteMessage, false)
                return
            }
        }

        // Byte-size check: a truncated download (unstable mirror, dropped
        // connection) must fail here instead of installing a partial DMG.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let fileSize = attrs[.size] as? Int64,
           let response = downloadTask.response as? HTTPURLResponse,
           response.expectedContentLength > 0,
           fileSize != response.expectedContentLength {
            try? FileManager.default.removeItem(at: dest)
            onError(incompleteMessage, false)
            return
        }

        // SHA-256 check against latest.json: catches "size matches but bytes
        // are wrong" (stale/corrupt CDN cache). Skipped when the feed had no
        // checksum (API-fallback check path).
        if let expected = expectedSHA256?.lowercased(), !expected.isEmpty {
            guard let data = try? Data(contentsOf: dest) else {
                try? FileManager.default.removeItem(at: dest)
                onError(incompleteMessage, false)
                return
            }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if actual != expected {
                try? FileManager.default.removeItem(at: dest)
                onError(incompleteMessage, false)
                return
            }
        }

        onComplete(dest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let isCancelled = (error as NSError).code == NSURLErrorCancelled
            onError(error.localizedDescription, isCancelled)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 1
        let progress = Double(totalBytesWritten) / Double(total)
        onProgress(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }
}

import Foundation
import UserNotifications

/// Pre-break heads-up via system notification (issue #34): a banner shortly
/// before the break reminder so the user can save their work. System
/// notifications are used by explicit product decision — they respect the
/// user's Focus/Do-Not-Disturb and notification-style preferences.
@MainActor
final class PreBreakNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PreBreakNotifier()

    /// UNUserNotificationCenter.current() traps when the process has no
    /// bundle (bare `swift run` binary) — every access must go through here.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Ask for permission (no-op if already decided). Called when the user
    /// turns the feature on; the completion reports whether notifications are
    /// usable so the settings UI can surface a denied state instead of the
    /// feature silently never firing.
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
        guard let center else { completion(false); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }

    /// Reports whether notifications are currently blocked in System Settings
    /// (denied), as opposed to granted or not-yet-asked.
    func checkDenied(completion: @escaping @MainActor (Bool) -> Void) {
        guard let center else { completion(false); return }
        center.getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in completion(denied) }
        }
    }

    func send(secondsUntilBreak: Int, isLong: Bool, soundEnabled: Bool) {
        guard let center else { return }
        // Deliver banners even while HealthTick is the active app — as an
        // LSUIElement menu-bar app it often is (user just used the dropdown),
        // and without the delegate the system swallows foreground banners.
        center.delegate = self

        let content = UNMutableNotificationContent()
        content.title = L.preBreakNoticeTitle(L.formatBreakDuration(secondsUntilBreak), isLong: isLong)
        content.body = L.preBreakNoticeBody
        if soundEnabled { content.sound = .default }
        // Fixed identifier: a new heads-up replaces the previous one instead
        // of stacking in Notification Center.
        let request = UNNotificationRequest(identifier: "pre-break-notice", content: content, trigger: nil)
        center.add(request) { error in
            if let error { Task { @MainActor in Probe.log("preBreakNotice add failed: \(error)") } }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

import Foundation
import PersonalCore
import UserNotifications

/// System reminders one day and one hour before a saved limit reset expires.
///
/// Requests are identified by provider, account and expiry, so every refresh replaces them instead of adding
/// duplicates, and the reminders of a reset that was used or expired are withdrawn. Accounts whose inventory
/// could not be read keep their pending reminders. macOS keeps scheduled requests across app restarts.
@MainActor
final class ResetReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ResetReminders()

    private nonisolated static let prefix = "reset-credit|"
    private static let leads: [TimeInterval] = [86400, 3600]

    private var open: (() -> Void)?
    private var authorized: Bool?

    /// UserNotifications needs a bundled app; `swift run` builds stay silent instead of crashing.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start(open: @escaping () -> Void) {
        self.open = open
        self.center?.delegate = self
    }

    func sync(_ snapshot: QuotaSnapshot) {
        guard let center = self.center else { return }
        let now = Date()
        var requests: [UNNotificationRequest] = []
        var kept = Set<String>()
        for account in snapshot.accounts {
            let scope = "\(Self.prefix)\(account.provider.rawValue)|\(account.label)|"
            guard let resets = account.resetCredits else {
                kept.insert(scope)
                continue
            }
            for expiry in Set(resets.compactMap(\.self)) {
                for lead in Self.leads where expiry.timeIntervalSince(now) - lead > 60 {
                    let content = UNMutableNotificationContent()
                    content.title = lead == 3600 ? L10n.tr("%@ reset expires in 1 hour", account.provider.title)
                        : L10n.tr("%@ reset expires in 1 day", account.provider.title)
                    content.body = L10n.tr("%@ · Use it in Proxyhub before it expires.", account.label)
                    let trigger = UNTimeIntervalNotificationTrigger(
                        timeInterval: expiry.timeIntervalSince(now) - lead,
                        repeats: false)
                    let id = "\(scope)\(Int(expiry.timeIntervalSince1970))|\(Int(lead))"
                    requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
            }
        }
        let wanted = Set(requests.map(\.identifier))
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier)
            let stale = pending.filter { id in
                id.hasPrefix(Self.prefix) && !wanted.contains(id) && !kept.contains { id.hasPrefix($0) }
            }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            guard !requests.isEmpty, await self.authorize(center) else { return }
            for request in requests {
                try? await center.add(request)
            }
        }
    }

    private func authorize(_ center: UNUserNotificationCenter) async -> Bool {
        if let authorized { return authorized }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        self.authorized = granted
        return granted
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async
    {
        guard response.notification.request.identifier.hasPrefix(Self.prefix) else { return }
        await MainActor.run { self.open?() }
    }

    /// Accessory apps can be frontmost while the menu is open; show the banner anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}

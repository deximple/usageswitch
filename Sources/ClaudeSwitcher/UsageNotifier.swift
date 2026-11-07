import Foundation
import SwitcherCore
@preconcurrency import UserNotifications

/// Delivers usage alerts as macOS notifications. Authorization is requested lazily the first time
/// an alert would be shown; if the user declines, alerts are just skipped — nothing else changes.
enum UsageNotifier {
    static func deliver(_ alerts: [UsageAlerts.Alert], labelFor: (UsageAlerts.Alert) -> String) {
        // Resolve the bodies now: the auth callback is @Sendable and can't call back into the model.
        let ready: [(key: String, body: String)] = alerts.map { alert in
            (alert.key, L10n.t(.usageAlertBody, labelFor(alert),
                               UsageText.name(of: alert.window),
                               Int(alert.window.usedPercent.rounded())))
        }
        // Outside an app bundle (a bare `swift build` binary) the notification center throws.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for item in ready {
                let content = UNMutableNotificationContent()
                content.title = ProductInfo.name
                content.body = item.body
                // The pinned-row key is the identifier: a later alert for the same window replaces
                // the older one instead of stacking.
                center.add(UNNotificationRequest(identifier: "usage-\(item.key)",
                                                 content: content, trigger: nil))
            }
        }
    }
}

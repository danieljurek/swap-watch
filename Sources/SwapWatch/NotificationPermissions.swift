import Combine
import Foundation
import UserNotifications

struct NotificationAccess {
    let authorization: UNAuthorizationStatus
    let alerts: UNNotificationSetting
    let style: UNAlertStyle

    var allowsDelivery: Bool {
        authorization == .authorized || authorization == .provisional
    }
}

@MainActor
protocol NotificationPermissionClient {
    func settings() async -> NotificationAccess
    func request() async throws
}

struct SystemNotificationPermissionClient: NotificationPermissionClient {
    func settings() async -> NotificationAccess {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationAccess(
            authorization: settings.authorizationStatus,
            alerts: settings.alertSetting,
            style: settings.alertStyle
        )
    }

    func request() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}

/// User intent and OS authorization are independent. OS denial or an API
/// failure must never silently persist an opt-out on the user's behalf.
@MainActor
final class NotificationPermissions: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var access: NotificationAccess?
    @Published private(set) var requestError: String?
    @Published private(set) var isRequesting = false

    private let defaults: UserDefaults
    private let client: any NotificationPermissionClient

    init(defaults: UserDefaults = .standard, client: (any NotificationPermissionClient)? = nil) {
        self.defaults = defaults
        self.client = client ?? SystemNotificationPermissionClient()
        defaults.register(defaults: [PreferenceKeys.notificationsEnabled: true])
        isEnabled = defaults.bool(forKey: PreferenceKeys.notificationsEnabled)
    }

    var canDeliver: Bool { isEnabled && (access?.allowsDelivery ?? false) }

    var statusMessage: String {
        if let requestError { return "Permission request failed: \(requestError)" }
        guard let access else { return "Checking macOS notification permission…" }
        switch access.authorization {
        case .notDetermined:
            return "macOS permission has not been granted. Choose Allow Notifications to request it."
        case .denied:
            return "Notifications are blocked in macOS. Enable SwapWatch in System Settings → Notifications."
        case .provisional:
            return "macOS allows quiet delivery only. Enable banners in System Settings → Notifications → SwapWatch."
        case .authorized:
            if access.alerts != .enabled || access.style == .none {
                return "Permission granted, but banners are off. Enable an alert style in System Settings → Notifications → SwapWatch."
            }
            return "macOS notification permission granted. Focus settings may silence alerts."
        default:
            return "macOS reported an unsupported notification permission state. Check System Settings → Notifications."
        }
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: PreferenceKeys.notificationsEnabled)
    }

    func refresh() async {
        access = await client.settings()
        if access?.allowsDelivery == true { requestError = nil }
    }

    func requestIfNeeded() async {
        guard isEnabled, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        await refresh()
        guard isEnabled, access?.authorization == .notDetermined else { return }
        requestError = nil
        do {
            try await client.request()
        } catch {
            let error = error as NSError
            requestError = "\(error.localizedDescription) (\(error.domain), \(error.code))"
        }
        await refresh()
    }
}

import Foundation
import UserNotifications
import XCTest
@testable import SwapWatch

@MainActor
final class NotificationPermissionsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "SwapWatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    func testDeniedPermissionPreservesEnabledPreferenceAndDoesNotPromptAgain() async {
        await withDefaults { defaults in
            let client = PermissionStub(.denied)
            let permissions = NotificationPermissions(defaults: defaults, client: client)
            await permissions.requestIfNeeded()
            XCTAssertTrue(permissions.isEnabled)
            XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.notificationsEnabled))
            XCTAssertFalse(permissions.canDeliver)
            XCTAssertEqual(client.requests, 0)
            XCTAssertTrue(permissions.statusMessage.contains("blocked in macOS"))
        }
    }

    func testRequestErrorIsVisibleWithoutPersistingAnOptOut() async {
        await withDefaults { defaults in
            let client = PermissionStub(.notDetermined)
            client.error = NSError(domain: "PermissionTest", code: 42,
                                   userInfo: [NSLocalizedDescriptionKey: "Request unavailable"])
            let permissions = NotificationPermissions(defaults: defaults, client: client)
            await permissions.requestIfNeeded()
            XCTAssertTrue(permissions.isEnabled)
            XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.notificationsEnabled))
            XCTAssertFalse(permissions.canDeliver)
            XCTAssertEqual(client.requests, 1)
            XCTAssertTrue(permissions.statusMessage.contains("Request unavailable"))
            XCTAssertTrue(permissions.statusMessage.contains("PermissionTest, 42"))
        }
    }

    func testDeniedResponseToFirstPromptKeepsPreferenceEnabled() async {
        await withDefaults { defaults in
            let client = PermissionStub(.notDetermined)
            client.result = NotificationAccess(authorization: .denied, alerts: .disabled, style: .none)
            let permissions = NotificationPermissions(defaults: defaults, client: client)
            await permissions.requestIfNeeded()
            XCTAssertEqual(permissions.access?.authorization, .denied)
            XCTAssertTrue(permissions.isEnabled)
            XCTAssertFalse(permissions.canDeliver)
        }
    }

    func testOptOutWhileRequestIsInFlightWinsOverLaterAuthorization() async {
        await withDefaults { defaults in
            let client = PermissionStub(.notDetermined)
            let permissions = NotificationPermissions(defaults: defaults, client: client)
            client.duringRequest = { permissions.setEnabled(false) }
            await permissions.requestIfNeeded()
            XCTAssertEqual(permissions.access?.authorization, .authorized)
            XCTAssertFalse(permissions.isEnabled)
            XCTAssertFalse(permissions.canDeliver)
            XCTAssertFalse(defaults.bool(forKey: PreferenceKeys.notificationsEnabled))
        }
    }

    func testRefreshDetectsChangesInSystemSettingsWithoutRequestingPermission() async {
        await withDefaults { defaults in
            let client = PermissionStub(.denied)
            let permissions = NotificationPermissions(defaults: defaults, client: client)
            await permissions.refresh()
            XCTAssertFalse(permissions.canDeliver)
            client.current = NotificationAccess(authorization: .authorized, alerts: .enabled, style: .banner)
            await permissions.refresh()
            XCTAssertTrue(permissions.canDeliver)
            client.current = NotificationAccess(authorization: .authorized, alerts: .disabled, style: .none)
            await permissions.refresh()
            XCTAssertTrue(permissions.statusMessage.contains("banners are off"))
            XCTAssertEqual(client.requests, 0)
        }
    }

    func testSavedOptOutSurvivesLaunchAndQuietDeliveryIsExplicit() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: PreferenceKeys.notificationsEnabled)
            let client = PermissionStub(.provisional)
            let permissions = NotificationPermissions(defaults: defaults, client: client)
            await permissions.requestIfNeeded()
            await permissions.refresh()
            XCTAssertFalse(permissions.isEnabled)
            XCTAssertFalse(permissions.canDeliver)
            XCTAssertEqual(client.requests, 0)
            XCTAssertTrue(permissions.statusMessage.contains("quiet delivery only"))
        }
    }
}

@MainActor
private final class PermissionStub: NotificationPermissionClient {
    var current: NotificationAccess
    var result = NotificationAccess(authorization: .authorized, alerts: .enabled, style: .banner)
    var error: Error?
    var duringRequest: (() -> Void)?
    var requests = 0

    init(_ authorization: UNAuthorizationStatus) {
        current = NotificationAccess(authorization: authorization, alerts: .disabled, style: .none)
    }

    func settings() async -> NotificationAccess { current }

    func request() async throws {
        requests += 1
        duringRequest?()
        if let error { throw error }
        current = result
    }
}

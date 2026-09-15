import AppKit
import Combine
import Dispatch
import Foundation
import SwapCore
import UserNotifications

private final class SwapWatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

enum PreferenceKeys {
    static let sustainedRate = "sustainedRateMiBPerSecond"
    static let frequentFraction = "frequentWriteFraction"
    static let notificationsEnabled = "notificationsEnabled"
}

@MainActor
final class SwapMonitorModel: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot?
    @Published private(set) var summary: MonitorSummary?
    @Published private(set) var fallbackPressure: MemoryPressure = .unknown
    @Published private(set) var samplingError: String?
    @Published private(set) var notificationsActive = false
    @Published private(set) var lastSuccessfulSampleAt: Date?

    private var sampler = SystemSampler()
    private var analyzer = SwapAnalyzer()
    private var thresholds: MonitorThresholds
    private var samplingTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lastNotificationDate: Date?
    private let notificationDelegate: SwapWatchNotificationDelegate

    init() {
        notificationDelegate = SwapWatchNotificationDelegate()
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            PreferenceKeys.sustainedRate: 5.0,
            PreferenceKeys.frequentFraction: 0.25,
            PreferenceKeys.notificationsEnabled: false
        ])
        thresholds = MonitorThresholds(
            sustainedMiBPerSecond: defaults.double(forKey: PreferenceKeys.sustainedRate),
            frequentWriteFraction: defaults.double(forKey: PreferenceKeys.frequentFraction)
        )
        UNUserNotificationCenter.current().delegate = notificationDelegate

        installMemoryPressureFallback()
        installWakeObserver()

        Task { @MainActor [weak self] in
            self?.start()
            if defaults.bool(forKey: PreferenceKeys.notificationsEnabled) {
                _ = await self?.restoreNotificationPreference()
            }
        }
    }

    deinit {
        samplingTask?.cancel()
        pressureSource?.cancel()
        for observer in lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var effectivePressure: MemoryPressure {
        if let sampled = snapshot?.pressure, sampled != .unknown {
            return sampled
        }
        return fallbackPressure
    }

    func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.takeSample()
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func updateThresholds(sustainedRate: Double, frequentFraction: Double) {
        thresholds = MonitorThresholds(
            sustainedMiBPerSecond: sustainedRate,
            frequentWriteFraction: frequentFraction
        )
    }

    func resetSession() {
        analyzer.reset()
        summary = nil
        takeSample()
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func restoreNotificationPreference() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        notificationsActive = allowed
        return allowed
    }

    func requestNotificationsFromUserAction() async -> Bool {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationsActive = allowed
            return allowed
        } catch {
            notificationsActive = false
            return false
        }
    }

    func disableNotifications() {
        notificationsActive = false
    }

    private func takeSample() {
        do {
            let newSnapshot = try sampler.sample()
            let newSummary = analyzer.ingest(newSnapshot, thresholds: thresholds)
            snapshot = newSnapshot
            summary = newSummary
            samplingError = nil
            lastSuccessfulSampleAt = newSnapshot.timestamp
            considerNotification(snapshot: newSnapshot, summary: newSummary)
        } catch {
            analyzer.invalidate()
            snapshot = nil
            summary = nil
            samplingError = "Live sampling unavailable: \(error.localizedDescription)"
        }
    }

    private func installMemoryPressureFallback() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            if event.contains(.critical) {
                self.fallbackPressure = .critical
            } else if event.contains(.warning) {
                self.fallbackPressure = .warning
            } else if event.contains(.normal) {
                self.fallbackPressure = .normal
            }
        }
        source.resume()
        pressureSource = source
    }

    private func installWakeObserver() {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fallbackPressure = .unknown
                self.analyzer.invalidate()
                self.snapshot = nil
                self.summary = nil
                self.samplingError = "Refreshing after wake…"
                self.takeSample()
            }
        }
        lifecycleObservers.append(observer)
    }

    private func considerNotification(snapshot: MemorySnapshot, summary: MonitorSummary) {
        guard notificationsActive else { return }
        if let lastNotificationDate, Date().timeIntervalSince(lastNotificationDate) < 300 {
            return
        }

        let pressure = snapshot.pressure == .unknown ? fallbackPressure : snapshot.pressure
        if pressure == .critical {
            postNotification(
                title: "Critical memory pressure",
                body: "Save work and close or pause memory-heavy apps."
            )
            return
        }

        guard summary.observedSeconds >= 30 else { return }
        switch summary.activity {
        case .frequent:
            postNotification(
                title: "Frequent swap writes",
                body: "SwapWatch detected frequent swap writes. Check Activity Monitor for memory-heavy apps."
            )
        case .sustained:
            postNotification(
                title: "Sustained swap writes",
                body: "SwapWatch detected sustained swap I/O. Check Activity Monitor for memory-heavy apps."
            )
        case .churning:
            postNotification(
                title: "Swap churn detected",
                body: "Frequent or sustained swap writes are accompanied by substantial reads. Check memory-heavy apps."
            )
        default:
            break
        }
    }

    private func postNotification(title: String, body: String) {
        lastNotificationDate = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "swapwatch-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

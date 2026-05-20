import Foundation
import CoreLocation

// MARK: - Background Keep-Alive
// Uses a silent, low-accuracy location update to keep the app alive in the
// background — the same technique used by MeloNX and similar emulators.
// Requires "When In Use" location permission and UIBackgroundModes = [location]
// in Info.plist.

@MainActor
public final class BackgroundKeepAlive: NSObject, ObservableObject {

    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "backgroundKeepAlive")
            isEnabled ? startMonitoring() : stopMonitoring()
        }
    }
    @Published public private(set) var authStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    public override init() {
        isEnabled = UserDefaults.standard.bool(forKey: "backgroundKeepAlive")
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter  = CLLocationDistanceMax
        authStatus = manager.authorizationStatus
        if isEnabled { startMonitoring() }
    }

    // MARK: - Internal

    private func startMonitoring() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates  = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    private func stopMonitoring() {
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
    }
}

// MARK: - CLLocationManagerDelegate

extension BackgroundKeepAlive: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authStatus = status
            if (status == .authorizedWhenInUse || status == .authorizedAlways) && self.isEnabled {
                self.startMonitoring()
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager,
                                            didUpdateLocations locations: [CLLocation]) {}
}

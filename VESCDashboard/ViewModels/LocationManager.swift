import Foundation
import CoreLocation
import Combine

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var speedKMH: Double? = nil
    @Published var isAuthorized = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        let status = manager.authorizationStatus
        isAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        speedKMH = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // speed == -1 means GPS has no velocity estimate (e.g. stationary).
        // Clamp to 0 so the badge shows "0.0" rather than "GPS…" once updates arrive.
        speedKMH = max(0.0, loc.speed) * 3.6
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        isAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
        if isAuthorized {
            manager.startUpdatingLocation()
        } else {
            speedKMH = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        speedKMH = nil
    }
}

import CoreLocation
import Foundation

/// One-shot device location for weather (macOS Core Location).
final class DeviceLocation: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = DeviceLocation()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private let lock = NSLock()

    enum LocationError: Error {
        case denied
        case unavailable
        case timeout
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func requestCurrentLocation() async throws -> CLLocation {
        let status = manager.authorizationStatus
        switch status {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // Wait briefly for the auth dialog result.
            try await waitForAuthorization()
            let updated = manager.authorizationStatus
            if updated == .denied || updated == .restricted {
                throw LocationError.denied
            }
        default:
            break
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
            lock.lock()
            if continuation != nil {
                lock.unlock()
                cont.resume(throwing: LocationError.unavailable)
                return
            }
            continuation = cont
            lock.unlock()
            manager.requestLocation()

            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard let pending = self.continuation else {
                    self.lock.unlock()
                    return
                }
                self.continuation = nil
                self.lock.unlock()
                pending.resume(throwing: LocationError.timeout)
            }
        }
    }

    private func waitForAuthorization() async throws {
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let s = manager.authorizationStatus
            if s != .notDetermined { return }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Auth wait loop polls status; nothing else needed here.
    }
}

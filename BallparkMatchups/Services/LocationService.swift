import Foundation
import CoreLocation

enum LocationResult {
    case success(CLLocationCoordinate2D)
    case denied
    case failed(Error?)
    case timeout
}

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<LocationResult, Never>?
    private var timeoutTask: Task<Void, Never>?

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Public API

    func requestLocation() async -> LocationResult {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // Wait for authorization
            let authResult = await waitForAuthorization()
            if authResult == .denied || authResult == .restricted {
                return .denied
            }
        default:
            break
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.startTimeout()
            self.manager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        Task { @MainActor in
            self.timeoutTask?.cancel()
            self.continuation?.resume(returning: .success(location.coordinate))
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.timeoutTask?.cancel()
            self.continuation?.resume(returning: .failed(error))
            self.continuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
        }
    }

    // MARK: - Private

    private func startTimeout() {
        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)  // 8s
            guard !Task.isCancelled else { return }
            self.continuation?.resume(returning: .timeout)
            self.continuation = nil
        }
    }

    private func waitForAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { cont in
            var attempts = 0
            Task {
                while manager.authorizationStatus == .notDetermined && attempts < 30 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    attempts += 1
                }
                cont.resume(returning: self.manager.authorizationStatus)
            }
        }
    }
}

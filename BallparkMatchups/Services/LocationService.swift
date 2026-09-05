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
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
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

        // If a previous request is still pending, resolve it before storing a new
        // continuation — overwriting it would strand the earlier caller forever.
        if let pending = continuation {
            timeoutTask?.cancel()
            continuation = nil
            pending.resume(returning: .failed(nil))
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
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            guard status != .notDetermined, let pending = self.authContinuation else { return }
            self.authContinuation = nil
            pending.resume(returning: status)
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

    /// Waits for the delegate to report the user's choice.
    ///
    /// This used to poll every 200ms and give up after 6 seconds, so a slow tap on
    /// Allow produced "Couldn't detect location". The system prompt is modal, so
    /// waiting for the real answer costs nothing.
    private func waitForAuthorization() async -> CLAuthorizationStatus {
        // The user may have answered between requesting and awaiting.
        let current = manager.authorizationStatus
        if current != .notDetermined { return current }

        if let stale = authContinuation {
            authContinuation = nil
            stale.resume(returning: current)
        }
        return await withCheckedContinuation { cont in
            authContinuation = cont
        }
    }
}

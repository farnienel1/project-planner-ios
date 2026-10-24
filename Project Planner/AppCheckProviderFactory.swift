//
//  AppCheckProviderFactory.swift
//  Project Planner
//
//  Registers one App Check provider factory before FirebaseApp.configure().
//  A factory set after configure is ignored.
//

import FirebaseAppCheck
import FirebaseCore

/// Shared by `FirebaseStartup.configureIfNeeded()` and `FirebaseBackend.ensureFirebaseAppConfigured()`.
/// The class name is not `AppCheckProviderFactory` because that name is the Firebase protocol.
nonisolated final class PlannerAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    private nonisolated(unsafe) static var didInstall = false

    /// Safe to call from every configure path. The factory is installed at most once.
    static func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        AppCheck.setAppCheckProviderFactory(PlannerAppCheckProviderFactory())
    }

    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator)
        return AppCheckDebugProvider(app: app)
        #else
        if #available(iOS 14.0, *) {
            return AppAttestProvider(app: app)
        } else {
            return DeviceCheckProvider(app: app)
        }
        #endif
    }
}

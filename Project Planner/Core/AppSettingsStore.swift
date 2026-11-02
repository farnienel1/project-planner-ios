//
//  AppSettingsStore.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
class AppSettingsStore: ObservableObject {
    @Published var settings: AppSettings = AppSettings()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private static let appearanceDefaultsKey = "appAppearanceMode"
    
    private let persistenceService: PersistenceService
    private weak var firebaseBackend: FirebaseBackend?
    private weak var smartCache: SmartCacheService?
    private var cancellables = Set<AnyCancellable>()
    
    init(persistenceService: PersistenceService? = nil) {
        self.persistenceService = persistenceService ?? PersistenceService()
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceDefaultsKey),
           let stored = ThemePreference(rawValue: raw) {
            settings.theme = stored
        }
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
        Task {
            await syncMyScheduleOptionsFromOrganization()
            await syncNotificationPreferencesFromFirebaseIfPossible()
        }
    }
    
    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
    }

    func setupObservers() {
        // Listen for user sign in/out notifications
        NotificationCenter.default.addObserver(
            forName: .userDidSignIn,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let userId = notification.object as? String {
                Task { @MainActor [weak self] in
                    self?.setCurrentUser(userId)
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .userDidSignOut,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setCurrentUser(nil)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .organizationDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncMyScheduleOptionsFromOrganization()
                self?.applyOrganizationMaterialCutOff()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .organizationMyScheduleOptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncMyScheduleOptionsFromOrganization()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .organizationMaterialCutOffDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyOrganizationMaterialCutOff()
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func setCurrentUser(_ userId: String?) {
        persistenceService.setCurrentUser(userId)
        loadSettings()
        Task { await syncNotificationPreferencesFromFirebaseIfPossible() }
    }
    
    // MARK: - Data Loading
    
    func loadSettings() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                var loadedSettings = try await persistenceService.loadAppSettings()
                // The organisation document owns My Schedule options; the device copy is never merged back
                // into it, so a deleted custom item stays deleted.
                if let backend = firebaseBackend,
                   backend.organizationHasFirestoreMyScheduleOptions,
                   let org = backend.currentOrganization {
                    loadedSettings.myScheduleOptions = org.settings.myScheduleOptions
                }
                self.settings = loadedSettings
                UserDefaults.standard.set(self.settings.theme.rawValue, forKey: Self.appearanceDefaultsKey)
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                // Keep existing in-memory settings on failure — do not wipe custom My Schedule items.
            }
        }
    }

    private static func myScheduleOptionsHasCustomizations(_ options: MyScheduleOptions) -> Bool {
        !options.customItems.isEmpty
            || !options.showOffice
            || !options.showWorkingFromHome
            || !options.showSiteSurvey
    }

    private func syncMyScheduleOptionsFromOrganization() async {
        guard let backend = firebaseBackend,
              let org = backend.currentOrganization else { return }

        if backend.organizationHasFirestoreMyScheduleOptions {
            settings.myScheduleOptions = org.settings.myScheduleOptions
            await persistSettingsWithoutMyScheduleMerge()
            return
        }

        let local = settings.myScheduleOptions
        guard Self.myScheduleOptionsHasCustomizations(local) else { return }
        do {
            try await backend.updateOrganizationMyScheduleOptions(local)
        } catch {
            errorMessage = "Failed to sync My Schedule options: \(error.localizedDescription)"
        }
    }

    private func syncNotificationPreferencesFromFirebaseIfPossible() async {
        guard let backend = firebaseBackend,
              let userId = backend.currentUser?.uid else { return }
        do {
            if let remote = try await backend.loadUserNotificationPreferences(userId: userId) {
                settings.notifications = remote
                applyOrganizationMaterialCutOff()
                await persistSettingsWithoutMyScheduleMerge()
            } else {
                try await backend.saveUserNotificationPreferences(settings.notifications, userId: userId)
            }
        } catch {
            errorMessage = "Failed to sync notification preferences: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Settings Operations
    
    func updateTheme(_ theme: ThemePreference) async {
        settings.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.appearanceDefaultsKey)
        theme.applyToKeyWindows()
        await saveSettingsLocallyOnly()
    }
    
    func updateColorScheme(_ colorScheme: AppColorScheme) async {
        settings.colorScheme = colorScheme
        await saveSettingsLocallyOnly()
    }
    
    func updateOrganization(_ organizationId: UUID?) async {
        settings.organizationId = organizationId
        await saveSettingsLocallyOnly()
    }
    
    func updateAutoSync(_ enabled: Bool) async {
        settings.autoSync = enabled
        await saveSettingsLocallyOnly()
    }
    
    /// Keeps the full local map. Firestore receives only `changedKeys`, each as its own dotted field.
    func updateNotifications(_ notificationSettings: NotificationSettings, changedKeys: [String: Bool]) async {
        settings.notifications = notificationSettings
        if let backend = firebaseBackend, let userId = backend.currentUser?.uid, !changedKeys.isEmpty,
           smartCache?.isOnline == false {
            // RULEBOOK §2: the user's own toggles are allowed offline — queued as dotted partial updates
            // (`userNotificationPreferenceFieldPatch`) and shown as Pending sync until the server confirms them.
            if let patch = CanonicalBusinessEngine.userNotificationPreferenceFieldPatch(changedKeys), !patch.isEmpty {
                OfflineOutboxStore.shared.enqueueOwnNotificationToggles(
                    userId: userId,
                    fields: patch.mapValues { OfflineFieldValue.bool($0) },
                    organizationId: backend.resolvedOrganizationIdForOfflineWrites() ?? ""
                )
            } else {
                errorMessage = "Failed to sync notification preferences."
            }
        } else if let backend = firebaseBackend, let userId = backend.currentUser?.uid, !changedKeys.isEmpty {
            do {
                try await backend.saveUserNotificationPreferenceKeys(changedKeys, userId: userId)
            } catch {
                errorMessage = "Failed to sync notification preferences: \(error.localizedDescription)"
            }
        }
        await saveSettingsLocallyOnly()
    }

    /// `settings.materialCutOff` wins over the signed-in user's notification copy.
    private func applyOrganizationMaterialCutOff() {
        guard let cutOff = firebaseBackend?.currentOrganization?.settings.materialCutOff else { return }
        settings.notifications = cutOff.applied(to: settings.notifications)
    }
    
    /// Saves exactly `options` (`scheduleOptionsWriteFields` in the backend). Nothing is merged with the
    /// previous list, so removing a custom item removes it.
    func updateMyScheduleOptions(_ options: MyScheduleOptions) async {
        settings.myScheduleOptions = options

        if let backend = firebaseBackend {
            do {
                try await backend.updateOrganizationMyScheduleOptions(options)
                if let saved = backend.currentOrganization?.settings.myScheduleOptions {
                    settings.myScheduleOptions = saved
                }
            } catch {
                errorMessage = "Failed to sync My Schedule options: \(error.localizedDescription)"
            }
        }
        await saveSettingsLocallyOnly()
    }
    
    // MARK: - Persistence
    
    private func saveSettingsLocallyOnly() async {
        do {
            try await persistenceService.saveAppSettings(settings)
        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    private func persistSettingsWithoutMyScheduleMerge() async {
        do {
            try await persistenceService.saveAppSettings(settings)
        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }
    
    func resetToDefaults() async {
        settings = AppSettings()
        await saveSettingsLocallyOnly()
    }
}

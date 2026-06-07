//
//  AppSettingsStore.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import Foundation
import Combine

@MainActor
class AppSettingsStore: ObservableObject {
    @Published var settings: AppSettings = AppSettings()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    private let persistenceService: PersistenceService
    private weak var firebaseBackend: FirebaseBackend?
    private var cancellables = Set<AnyCancellable>()
    
    init(persistenceService: PersistenceService? = nil) {
        self.persistenceService = persistenceService ?? PersistenceService()
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
        Task {
            await syncMyScheduleOptionsFromOrganization()
            await syncNotificationPreferencesFromFirebaseIfPossible()
        }
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
            let previousOptions = settings.myScheduleOptions
            do {
                let loadedSettings = try await persistenceService.loadAppSettings()
                self.settings = Self.mergedSettings(loaded: loadedSettings, preserving: previousOptions)
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                // Keep existing in-memory settings on failure — do not wipe custom My Schedule items.
            }
        }
    }

    /// Preserves custom My Schedule locations across reloads and merges enabled flags.
    private static func mergedSettings(loaded: AppSettings, preserving previous: MyScheduleOptions) -> AppSettings {
        var merged = loaded
        var items = Set(previous.customItems)
        items.formUnion(loaded.myScheduleOptions.customItems)
        merged.myScheduleOptions.customItems = items.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for item in merged.myScheduleOptions.customItems {
            let enabled = loaded.myScheduleOptions.customItemEnabled[item]
                ?? previous.customItemEnabled[item]
                ?? true
            merged.myScheduleOptions.customItemEnabled[item] = enabled
        }
        return merged
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
    
    func updateNotifications(_ notificationSettings: NotificationSettings) async {
        settings.notifications = notificationSettings
        if let backend = firebaseBackend, let userId = backend.currentUser?.uid {
            do {
                try await backend.saveUserNotificationPreferences(notificationSettings, userId: userId)
            } catch {
                errorMessage = "Failed to sync notification preferences: \(error.localizedDescription)"
            }
        }
        await saveSettingsLocallyOnly()
    }
    
    func updateMyScheduleOptions(_ options: MyScheduleOptions) async {
        settings.myScheduleOptions = Self.mergedSettings(
            loaded: AppSettings(myScheduleOptions: options),
            preserving: settings.myScheduleOptions
        ).myScheduleOptions

        if let backend = firebaseBackend {
            do {
                try await backend.updateOrganizationMyScheduleOptions(settings.myScheduleOptions)
            } catch {
                errorMessage = "Failed to sync My Schedule options: \(error.localizedDescription)"
            }
        }
        await saveSettingsLocallyOnly()
    }
    
    // MARK: - Persistence
    
    private func saveSettingsLocallyOnly() async {
        do {
            var toSave = settings
            if let onDisk = try? await persistenceService.loadAppSettings() {
                toSave = Self.mergedSettings(loaded: toSave, preserving: onDisk.myScheduleOptions)
            }
            settings = toSave
            try await persistenceService.saveAppSettings(toSave)
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

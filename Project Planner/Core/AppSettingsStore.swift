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
    private var cancellables = Set<AnyCancellable>()
    
    init(persistenceService: PersistenceService? = nil) {
        self.persistenceService = persistenceService ?? PersistenceService()
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
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func setCurrentUser(_ userId: String?) {
        persistenceService.setCurrentUser(userId)
        loadSettings()
    }
    
    // MARK: - Data Loading
    
    func loadSettings() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let loadedSettings = try await persistenceService.loadAppSettings()
                self.settings = loadedSettings
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                // Use default settings if loading fails
                self.settings = AppSettings()
            }
        }
    }
    
    // MARK: - Settings Operations
    
    func updateTheme(_ theme: ThemePreference) async {
        settings.theme = theme
        await saveSettings()
    }
    
    func updateColorScheme(_ colorScheme: AppColorScheme) async {
        settings.colorScheme = colorScheme
        await saveSettings()
    }
    
    func updateOrganization(_ organizationId: UUID?) async {
        settings.organizationId = organizationId
        await saveSettings()
    }
    
    func updateAutoSync(_ enabled: Bool) async {
        settings.autoSync = enabled
        await saveSettings()
    }
    
    func updateNotifications(_ notificationSettings: NotificationSettings) async {
        settings.notifications = notificationSettings
        await saveSettings()
    }
    
    func updateMyScheduleOptions(_ options: MyScheduleOptions) async {
        settings.myScheduleOptions = options
        await saveSettings()
    }
    
    // MARK: - Persistence
    
    private func saveSettings() async {
        do {
            try await persistenceService.saveAppSettings(settings)
        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }
    
    func resetToDefaults() async {
        settings = AppSettings()
        await saveSettings()
    }
}

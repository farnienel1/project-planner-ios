//
//  LocalNotificationService.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation
import UserNotifications

@MainActor
class LocalNotificationService {
    static let shared = LocalNotificationService()
    
    private init() {}
    
    // Request notification permissions
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            print("🔥🔥🔥 DEBUG: Error requesting notification authorization: \(error)")
            return false
        }
    }
    
        // Schedule a test notification 3 seconds in the future
    func scheduleTestNotification(type: AppNotification.NotificationType, details: String) async {
        // Request permission first
        let authorized = await requestAuthorization()
        guard authorized else {
            print("🔥🔥🔥 DEBUG: Notification permission not granted")
            return
        }
        
        // Create notification content
        let content = UNMutableNotificationContent()
        
        // Set title and body based on type
        switch type {
        case .operativeCreated:
            content.title = "New Operative Created"
            content.body = details.isEmpty ? "John Smith has been added as a new operative." : details
        case .managerCreated:
            content.title = "New Manager Created"
            content.body = details.isEmpty ? "Jane Doe has been added as a new manager." : details
        case .clientCreated:
            content.title = "New Client Created"
            content.body = details.isEmpty ? "ABC Company has been added as a new client." : details
        case .projectCreated:
            content.title = "New Project"
            content.body = details.isEmpty ? "A new project was added to your organisation." : details
        case .smallWorksCreated:
            content.title = "New Small Works"
            content.body = details.isEmpty ? "New small works were added to your organisation." : details
        case .bookingCreated:
            content.title = "New Booking Created"
            content.body = details.isEmpty ? "A new booking has been created for Project XYZ on December 1, 2025." : details
        case .taskCreated:
            content.title = "New Task Created"
            content.body = details.isEmpty ? "A new task has been assigned: Complete site inspection." : details
        case .taskCompleted:
            content.title = "Task Completed"
            content.body = details.isEmpty ? "Task 'Complete site inspection' has been completed." : details
        case .bookingClash:
            content.title = "Booking Clash Detected"
            content.body = details.isEmpty ? "A booking clash has been detected for John Smith on December 1, 2025." : details
        case .holidayRequestSubmitted:
            content.title = "Holiday Request"
            content.body = details.isEmpty ? "An operative has submitted a holiday request." : details
        case .holidayRequestApproved:
            content.title = "Holiday Approved"
            content.body = details.isEmpty ? "A holiday request has been approved." : details
        case .holidayRequestDeclined:
            content.title = "Holiday Declined"
            content.body = details.isEmpty ? "A holiday request has been declined." : details
        }
        
        // Set sound
        content.sound = .default
        
        // Set badge
        content.badge = 1
        
        // Create trigger for 3 seconds from now
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        
        // Create request with unique identifier
        let identifier = "test_notification_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        // Schedule the notification
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("✅ Test notification scheduled: \(content.title) - will appear in 3 seconds")
        } catch {
            print("🔥🔥🔥 DEBUG: Error scheduling notification: \(error)")
        }
    }
    
    // Schedule a test notification with custom title and body
    func scheduleCustomTestNotification(title: String, body: String) async {
        // Request permission first
        let authorized = await requestAuthorization()
        guard authorized else {
            print("🔥🔥🔥 DEBUG: Notification permission not granted")
            return
        }
        
        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = 1
        
        // Create trigger for 3 seconds from now
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        
        // Create request with unique identifier
        let identifier = "test_notification_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        // Schedule the notification
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("✅ Custom test notification scheduled: \(title) - will appear in 3 seconds")
        } catch {
            print("🔥🔥🔥 DEBUG: Error scheduling notification: \(error)")
        }
    }
}



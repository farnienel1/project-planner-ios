# Project Planner

A modern iOS project management application built with SwiftUI for construction teams.

## Features

- **Project Management**: Track projects from start to finish with detailed information
- **Team Management**: Manage operatives and their skills, qualifications, and availability
- **Scheduling**: Schedule work assignments and detect conflicts
- **Real-time Updates**: Live data synchronization across the app
- **Modern UI**: Clean, intuitive interface built with SwiftUI

## Architecture

The app is built with a clean, modular architecture:

### Models
- `ProjectModels.swift` - Core project and client data structures
- `PeopleModels.swift` - Operative and manager data structures
- `BookingModels.swift` - Scheduling and booking data structures
- `AppModels.swift` - App configuration and settings models

### Core
- `ProjectStore.swift` - Project data management and operations
- `OperativeStore.swift` - Operative and manager data management
- `BookingStore.swift` - Booking and scheduling management
- `AppSettingsStore.swift` - App settings and preferences
- `PersistenceService.swift` - Data persistence layer

### Views
- `HomeView.swift` - Dashboard with overview and quick stats
- `ProjectsView.swift` - Project listing and management
- `ScheduleView.swift` - Calendar and booking management
- `OperativesView.swift` - Team member management
- `SettingsView.swift` - App settings and configuration

## Key Features

### Project Management
- Create and manage construction projects
- Track project status (upcoming, active, completed, inactive)
- Associate projects with clients and managers
- Monitor project progress and deadlines

### Team Management
- Manage operatives with skills and qualifications
- Track manager information and contact details
- Monitor team availability and workload

### Scheduling
- Schedule operatives for specific time slots
- Detect and resolve booking conflicts
- View daily, weekly, and monthly schedules
- Track booking status and changes

### Data Persistence
- Local data storage using UserDefaults
- Automatic data synchronization
- Export/import functionality
- Data backup and recovery

## Getting Started

1. Open the project in Xcode
2. Build and run on your preferred simulator or device
3. The app will load with sample data for demonstration

## Requirements

- iOS 15.0+
- Xcode 13.0+
- Swift 5.5+

## Future Enhancements

- Cloud synchronization with Firebase
- Advanced reporting and analytics
- Push notifications
- Offline support
- Multi-organization support
- Advanced conflict resolution
- Time tracking and reporting
- Integration with external calendar systems

## License

This project is proprietary software. All rights reserved.


//
//  ClientsView.swift
//  Project Planner
//
//  Created by Assistant on 27/10/2025.
//

import SwiftUI

struct ClientsView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreateClient = false
    @State private var selectedClient: Client? = nil
    @State private var showingClientDetails = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                clientsNavyHeader

                VStack(spacing: 0) {
                    if projectStore.clients.isEmpty {
                        // Empty state
                        VStack(spacing: 16) {
                            PPIconTile(symbol: "person.2.fill", family: .people, size: PPMetrics.quickActionIcon, lifted: true)

                            Text("No Clients Added Yet")
                                .font(.system(.title2, design: .rounded))
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)

                            Text("Add clients to your organisation. Clients are the companies or individuals you work for.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Button("Create Client") {
                                showingCreateClient = true
                            }
                            .accessibilityIdentifier("clients.createClient")
                            .ppProminentCapsule()
                            .padding(.top, 4)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                        .padding(.top, 20)
                    } else {
                        // List of clients in card style
                        ScrollView {
                            VStack(spacing: 10) {
                                PPGroupLabel(text: "Clients")
                                    .padding(.top, -8)
                                ForEach(projectStore.clients) { client in
                                    ClientCardView(client: client)
                                        
                                        .accessibilityIdentifier("clients.tap").onTapGesture {
                                            selectedClient = client
                                            showingClientDetails = true
                                        }
                                }
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 24)
                        }
                    }
                    
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .ppContentSheet()
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Clients")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("clients.done")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("New Client") {
                        showingCreateClient = true
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("clients.newClient")
                }
            }
            .sheet(isPresented: $showingCreateClient) {
                CreateClientView()
                    .environmentObject(projectStore)
                    .environmentObject(notificationService)
                    .environmentObject(userStore)
                    .onDisappear {
                        projectStore.loadData()
                    }
            }
            .sheet(isPresented: $showingClientDetails) {
                if let client = selectedClient {
                    ClientDetailsView(client: client)
                        .environmentObject(projectStore)
                        .onDisappear {
                            projectStore.loadData()
                        }
                }
            }
        }
    }

    /// Home-style navy header with the number of clients already loaded.
    private var clientsNavyHeader: some View {
        let count = projectStore.clients.count
        return VStack(alignment: .leading, spacing: 8) {
            PPOverviewTitle(
                eyebrow: "Your clients",
                count: "\(count)",
                countLabel: count == 1 ? "client" : "clients"
            )
            Text("The companies or individuals you work for.")
                .font(.footnote)
                .foregroundStyle(PPColor.onNavySecondary)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }
}

// MARK: - Client Card View
struct ClientCardView: View {
    let client: Client
    
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            PPIconTile(symbol: "building.2.fill", family: .people, size: 38)

            VStack(alignment: .leading, spacing: 6) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    Text(client.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    
                    Spacer(minLength: 8)
                    
                    if let phone = client.phone, !phone.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "phone.fill")
                                .font(.caption2)
                            Text(phone)
                                .font(.footnote.weight(.medium))
                                .monospacedDigit()
                        }
                        .foregroundStyle(PPFamily.sites.bottom)
                    }
                }
                
                if let email = client.email, !email.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "envelope.fill")
                            .font(.caption2)
                            .foregroundStyle(PPFamily.plan.bottom)
                        Text(email)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Address if available
                if let address = client.address, !address.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                            .foregroundStyle(PPFamily.trade.bottom)
                        Text(address)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
    }
}

// MARK: - Client Details View
struct ClientDetailsView: View {
    let client: Client
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditClient = false
    
    private var clientProjects: [Project] {
        WorkAccess.visibleWorks(
            from: projectStore.projects.filter { $0.client.id == client.id },
            catalogue: .all,
            userStore: userStore,
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            managerBookings: managerScheduleStore.managerSiteBookings,
            taskStore: taskStore
        )
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Client Info Card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(client.name)
                                    .font(.largeTitle)
                                    .fontWeight(.bold)
                                
                                if let email = client.email, !email.isEmpty {
                                    HStack(spacing: 8) {
                                        Image(systemName: "envelope.fill")
                                            .foregroundColor(.blue)
                                        Text(email)
                                            .font(.body)
                                    }
                                }
                                
                                if let phone = client.phone, !phone.isEmpty {
                                    HStack(spacing: 8) {
                                        Image(systemName: "phone.fill")
                                            .foregroundColor(.green)
                                        Text(phone)
                                            .font(.body)
                                    }
                                }
                                
                                if let address = client.address, !address.isEmpty {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "location.fill")
                                            .foregroundColor(.orange)
                                        Text(address)
                                            .font(.body)
                                    }
                                }
                            }
                            
                            Spacer()
                        }
                    }
                    .padding()
                    .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                    
                    // Projects Section
                    if !clientProjects.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Projects (\(clientProjects.count))")
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.bold)
                            
                            ForEach(clientProjects) { project in
                                ProjectDetailRowView(project: project)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Client Details")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("clientDetails.done")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") {
                        showingEditClient = true
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("clientDetails.edit")
                }
            }
            .sheet(isPresented: $showingEditClient) {
                EditClientView(client: client)
                    .environmentObject(projectStore)
                    .onDisappear {
                        projectStore.loadData()
                    }
            }
        }
    }
}


#Preview {
    ClientsView()
        .environmentObject(ProjectStore())
}


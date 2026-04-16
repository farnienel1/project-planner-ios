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
            VStack {
                if projectStore.clients.isEmpty {
                    // Empty state - similar to SkillsManagementView
                    VStack(spacing: 20) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No Clients Added Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Add clients to your organisation. Clients are the companies or individuals you work for.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button("Create Client") {
                            showingCreateClient = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    // List of clients in card style
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(projectStore.clients) { client in
                                ClientCardView(client: client)
                                    .onTapGesture {
                                        selectedClient = client
                                        showingClientDetails = true
                                    }
                            }
                        }
                        .padding()
                    }
                }
                
                Spacer()
            }
            .navigationTitle("Clients")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("New Client") {
                        showingCreateClient = true
                    }
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
}

// MARK: - Client Card View
struct ClientCardView: View {
    let client: Client
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(client.name)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    if let email = client.email, !email.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "envelope.fill")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text(email)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                if let phone = client.phone, !phone.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "phone.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text(phone)
                                .font(.caption)
                                .foregroundColor(.green)
                                .fontWeight(.medium)
                        }
                    }
                }
            }
            
            // Address if available
            if let address = client.address, !address.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Client Details View
struct ClientDetailsView: View {
    let client: Client
    @EnvironmentObject var projectStore: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditClient = false
    
    private var clientProjects: [Project] {
        projectStore.projects.filter { $0.client.id == client.id }
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
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // Projects Section
                    if !clientProjects.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Projects (\(clientProjects.count))")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            ForEach(clientProjects) { project in
                                ProjectDetailRowView(project: project)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Client Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") {
                        showingEditClient = true
                    }
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


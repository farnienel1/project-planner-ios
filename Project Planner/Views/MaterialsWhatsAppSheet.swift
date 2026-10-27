//
//  MaterialsWhatsAppSheet.swift
//  Project Planner
//
//  Web parity: components/projects/materials/MaterialsSendListSheet.tsx "Send via WhatsApp".
//  Opens WhatsApp with the message prepared. The user presses Send in WhatsApp;
//  this does not mark the list as sent and writes no send record.
//

import SwiftUI
import UIKit

struct MaterialsWhatsAppSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let project: Project
    let materials: [MaterialItem]
    let recipients: [MaterialWhatsAppRulebook.Recipient]
    let deliveryAt: Date?
    /// Wholesaler that owns each contact id, for "Save mobile to this contact".
    let wholesalers: [Wholesaler]
    var onContactPhoneSaved: () -> Void = {}

    @State private var requestType: MaterialOrderRequest.RequestType = .order
    @State private var recipientId: String = ""
    @State private var phone: String = ""
    @State private var hint: String?
    @State private var isSavingPhone = false

    private var activeRecipient: MaterialWhatsAppRulebook.Recipient? {
        recipients.first(where: { $0.id == recipientId }) ?? recipients.first
    }

    private var owningWholesaler: Wholesaler? {
        guard let id = activeRecipient.flatMap({ UUID(uuidString: $0.id) }) else { return nil }
        return wholesalers.first { $0.contacts.contains(where: { $0.id == id }) }
    }

    private var row: MaterialWhatsAppRulebook.Row? {
        guard var recipient = activeRecipient else { return nil }
        recipient.phone = phone
        let user = userStore.currentUser
        let userName = user?.fullName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let input = MaterialWhatsAppRulebook.Input(
            requestType: requestType,
            organisationName: firebaseBackend.currentOrganization?.name ?? "",
            requestingUserName: userName.isEmpty ? (user?.email ?? "") : userName,
            jobNumber: project.jobNumber,
            projectName: project.siteName,
            projectAddress: project.siteAddress,
            deliveryAt: CanonicalBusinessEngine.materialOrderIncludesDeliveryRequired(requestType.rawValue) == true ? deliveryAt : nil,
            countryCode: firebaseBackend.currentOrganization?.countryCode ?? "GB",
            materials: materials.map { item in
                MaterialWhatsAppRulebook.Line(
                    material: item.material,
                    quantity: item.quantity,
                    unit: item.unit.rawValue,
                    brand: item.brand,
                    productCode: item.productCode,
                    notes: item.notes,
                    lengthDisplay: item.formattedLengthSpecification.isEmpty ? nil : item.formattedLengthSpecification
                )
            },
            recipients: [recipient]
        )
        return MaterialWhatsAppRulebook.rows(for: input)?.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Type", selection: $requestType) {
                        Text("Order").tag(MaterialOrderRequest.RequestType.order)
                        Text("Quote").tag(MaterialOrderRequest.RequestType.quote)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("materialsWhatsApp.type")

                    recipientCard

                    if let row {
                        if !row.ok, let reason = row.reason {
                            Text(reason)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        } else if let digits = row.digits {
                            Text("WhatsApp will open a chat with +\(digits)")
                                .font(.system(size: 11))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                        }
                        Text(row.message)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(MaterialsOrderingTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text("WhatsApp messages are not available yet. Update the app, or email the list instead.")
                            .font(.system(size: 13))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                    }

                    if let hint {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                    }

                    HStack(spacing: 8) {
                        Button {
                            guard let message = row?.message else { return }
                            UIPasteboard.general.string = message
                            hint = "Message copied."
                        } label: {
                            Label("Copy message", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("materialsWhatsApp.copy")
                        .buttonStyle(.bordered)
                        .disabled(row == nil)

                        Button {
                            openWhatsApp()
                        } label: {
                            Label("Open WhatsApp", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("materialsWhatsApp.open")
                        .buttonStyle(.borderedProminent)
                        .tint(MaterialsOrderingTheme.success)
                        .disabled(row?.ok != true)
                    }
                }
                .padding(16)
            }
            .background(MaterialsOrderingTheme.pageBackground)
            .navigationTitle("WhatsApp message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                        .accessibilityIdentifier("materialsWhatsApp.back")
                }
            }
            .onAppear {
                if let first = recipients.first, recipientId.isEmpty {
                    recipientId = first.id
                    phone = first.phone
                }
            }
        }
    }

    private var recipientCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recipients.count > 1 {
                Picker("Contact", selection: $recipientId) {
                    ForEach(recipients, id: \.id) { recipient in
                        Text(recipient.wholesalerName.map { "\(recipient.name) · \($0)" } ?? recipient.name)
                            .tag(recipient.id)
                    }
                }
                .accessibilityIdentifier("materialsWhatsApp.contact")
                .onChange(of: recipientId) { _, newId in
                    phone = recipients.first(where: { $0.id == newId })?.phone ?? ""
                    hint = nil
                }
            } else if let recipient = activeRecipient {
                Text(recipient.name)
                    .font(.system(size: 14, weight: .semibold))
                if let firm = recipient.wholesalerName, !firm.isEmpty {
                    Text(firm)
                        .font(.system(size: 12))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                }
            }
            TextField("Mobile (for WhatsApp)", text: $phone)
                .accessibilityIdentifier("materialsWhatsApp.mobile")
                .keyboardType(.phonePad)
                .textFieldStyle(.roundedBorder)
                .onChange(of: phone) { _, _ in hint = nil }
            if owningWholesaler != nil,
               !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               phone.trimmingCharacters(in: .whitespacesAndNewlines) != (activeRecipient?.phone ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
                Button(isSavingPhone ? "Saving…" : "Save mobile to this contact") {
                    Task { await saveMobileToContact() }
                }
                .accessibilityIdentifier("materialsWhatsApp.saveMobile")
                .font(.system(size: 12, weight: .semibold))
                .disabled(isSavingPhone)
            }
        }
        .padding(12)
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func openWhatsApp() {
        guard let row else { return }
        guard row.ok, let url = row.url else {
            hint = row.reason
            return
        }
        UIApplication.shared.open(url) { opened in
            hint = opened
                ? "WhatsApp opened with your order message prepared. Press Send in WhatsApp yourself — this does not mark the order as sent."
                : "Unable to open WhatsApp. Copy the message and paste it there."
        }
    }

    private func saveMobileToContact() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              var wholesaler = owningWholesaler,
              let contactId = activeRecipient.flatMap({ UUID(uuidString: $0.id) }) else { return }
        isSavingPhone = true
        defer { isSavingPhone = false }
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        wholesaler.contacts = wholesaler.contacts.map { contact in
            guard contact.id == contactId else { return contact }
            var updated = contact
            updated.phone = trimmed
            return updated
        }
        wholesaler.updatedAt = Date()
        do {
            try await firebaseBackend.saveWholesaler(wholesaler, organizationId: organizationId)
            hint = "Mobile number saved to this contact."
            onContactPhoneSaved()
        } catch {
            hint = error.localizedDescription.isEmpty ? "Could not save the mobile number." : error.localizedDescription
        }
    }
}

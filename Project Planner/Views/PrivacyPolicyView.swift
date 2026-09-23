//
//  PrivacyPolicyView.swift
//  Project Planner
//
//  Privacy & terms: the same customer legal pack as first-time sign-in / web.
//

import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isAcceptanceRequired: Bool
    var onAccept: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Privacy & terms")
                            .font(.title)
                            .fontWeight(.bold)
                        Text(CustomerLegalPack.summary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Text(CustomerLegalPack.toolboxTalkDisclaimer)
                        .font(.footnote)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    ForEach(CustomerLegalPack.documents) { document in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(document.title)
                                .font(.headline)
                            Text(document.intro)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(document.body)
                                .font(.footnote)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if isAcceptanceRequired {
                        Button(action: { onAccept?() }) {
                            Text("I Accept")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                        }
                        .padding(.bottom)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Privacy & terms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isAcceptanceRequired {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

struct SectionView<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            content
                .font(.body)
                .foregroundColor(.primary)
        }
        .padding(.horizontal)
    }
}

struct BulletPoint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.body)
            Text(text)
                .font(.body)
        }
    }
}

#Preview {
    PrivacyPolicyView(isAcceptanceRequired: .constant(false))
}

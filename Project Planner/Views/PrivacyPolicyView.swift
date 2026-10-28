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
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Privacy & terms")
                            .font(.system(.largeTitle, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                        Text(CustomerLegalPack.summary)
                            .font(.subheadline)
                            .foregroundStyle(PPColor.onNavySecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, PPMetrics.screenGutter)
                    .padding(.top, 16)
                    .padding(.bottom, PPMetrics.headerBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ppNavyHeader()

                    VStack(alignment: .leading, spacing: 18) {
                        CustomerLegalWebLinks()

                        Text(CustomerLegalPack.toolboxTalkDisclaimer)
                            .font(.footnote)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PPFamily.trade.top.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

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
                            .background(PPColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                        }

                        if isAcceptanceRequired {
                            Button(action: { onAccept?() }) {
                                Text("I Accept")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(PPColor.brand)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .accessibilityIdentifier("privacyPolicy.iAccept")
                            .padding(.bottom)
                        }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 16)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Privacy & terms")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                if !isAcceptanceRequired {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("privacyPolicy.done")
                            .font(.body.weight(.semibold))
                            .tint(.white)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PPColor.page)
    }
}

struct CustomerLegalWebLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            legalLink("Privacy on web", identifier: "legalWeb.privacy") {
                AppBranding.openPrivacyPolicy()
            }
            legalLink("Terms on web", identifier: "legalWeb.terms") {
                AppBranding.openTermsOfService()
            }
            legalLink("Processors on web", identifier: "legalWeb.processors") {
                AppBranding.openProcessors()
            }
        }
    }

    private func legalLink(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.blue)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(.isLink)
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

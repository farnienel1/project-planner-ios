import SwiftUI

/// Search and section chips for the organisation qualification library.
/// The ranking comes from `CanonicalBusinessEngine`. Organisation list, My Qualifications add, and Edit User share this view.
struct QualificationLibraryBrowser: View {
    let items: [Qualification]
    var selectedIds: Set<String> = []
    var activeId: String?
    var onToggle: ((Qualification) -> Void)?
    var onSelect: ((Qualification) -> Void)?
    var emptyLabel: String?
    var hint: String?

    @State private var query = ""
    @State private var section = CanonicalBusinessEngine.qualificationFilterAll

    var body: some View {
        let chips = CanonicalBusinessEngine.qualificationLibraryFilterChips(searchRecords) ?? []
        let visible = rankedItems
        VStack(alignment: .leading, spacing: 0) {
            searchField
            if chips.count > 1 {
                chipRow(chips)
            }
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if visible.isEmpty {
                Text(resolvedEmptyLabel)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
                    .padding(.horizontal, 16)
            } else {
                List {
                    ForEach(visible) { qualification in
                        Button {
                            if let onToggle {
                                onToggle(qualification)
                            } else {
                                onSelect?(qualification)
                            }
                        } label: {
                            row(qualification)
                        }
                        .accessibilityIdentifier("qualificationLibrary.row.\(qualification.id)")
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var searchRecords: [CanonicalBusinessEngine.CanonicalQualificationSearchRecord] {
        items.map { item in
            CanonicalBusinessEngine.CanonicalQualificationSearchRecord(
                name: item.name,
                code: item.code ?? "",
                awardingBody: item.awardingBody ?? "",
                section: item.section ?? "",
                subsection: item.subsection ?? "",
                notes: item.notes ?? ""
            )
        }
    }

    private var rankedItems: [Qualification] {
        guard let hits = CanonicalBusinessEngine.rankQualificationRecords(
            query: query,
            records: searchRecords,
            section: section
        ) else { return [] }
        return hits.compactMap { hit in
            items.indices.contains(hit.index) ? items[hit.index] : nil
        }
    }

    private var resolvedEmptyLabel: String {
        if let emptyLabel, !emptyLabel.isEmpty { return emptyLabel }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty || section != CanonicalBusinessEngine.qualificationFilterAll {
            return "No qualifications match that search."
        }
        return "No qualifications in this list."
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search qualifications", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("qualificationLibrary.search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func chipRow(_ chips: [CanonicalBusinessEngine.CanonicalQualificationFilterChip]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.key) { chip in
                    let selected = section == chip.key
                    Button {
                        section = chip.key
                    } label: {
                        Text("\(chip.label) · \(chip.count)")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(selected ? Color.blue : Color(.secondarySystemBackground))
                            .clipShape(Capsule())
                    }
                    .accessibilityIdentifier("qualificationLibrary.chip.\(chip.key)")
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func row(_ qualification: Qualification) -> some View {
        let selected = selectedIds.contains(qualification.id)
        let active = activeId == qualification.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(qualification.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let subtitle = qualification.librarySubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if onToggle != nil {
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(.blue)
            } else if active {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

import SwiftUI

/// Choosing a vendor never discards the other's result: switching back to a
/// vendor checked this session restores it instantly, an unchecked one is
/// verified right away. Running jobs keep the provider they started with.
struct AIVendorPicker: View {
    let settings: AppSettings
    var compact = false
    private static let icons = Dictionary(uniqueKeysWithValues: AIVendor.allCases.map {
        ($0, NSImage(contentsOf: AppResources.directory.appendingPathComponent($0.iconResource)))
    })

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            ForEach(AIVendor.allCases) { vendor in card(vendor) }
        }.accessibilityElement(children: .contain).accessibilityLabel("사용할 AI")
    }

    private func card(_ vendor: AIVendor) -> some View {
        let selected = settings.vendor == vendor
        let status = AIVendorStatus(settings: settings, vendor: vendor)
        return Button {
            guard !selected else { return }
            withAnimation(.easeOut(duration: 0.15)) { settings.vendor = vendor }
        } label: {
            HStack(alignment: compact ? .center : .top, spacing: compact ? 9 : 12) {
                if let icon = Self.icons[vendor] ?? nil {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: compact ? 22 : 32, height: compact ? 22 : 32)
                        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                    HStack(spacing: 6) {
                        Text(vendor.name).font(.system(size: compact ? 13 : 14, weight: .semibold))
                        if !compact { Text(vendor.accountName == vendor.name ? "구독" : vendor.accountName + " 계정")
                            .font(.system(size: 11)).foregroundStyle(SoriTheme.secondary) }
                    }
                    statusLine(status)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: compact ? 14 : 16)).foregroundStyle(selected ? SoriTheme.ink : SoriTheme.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, compact ? 11 : 14).padding(.vertical, compact ? 9 : 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? SoriTheme.ink : SoriTheme.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .help(selected ? "\(vendor.name) 사용 중" : "\(vendor.name)로 전환")
            .accessibilityLabel("\(vendor.name), \(status.label)\(status.model.map { ", " + $0 } ?? "")")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityHint(selected ? "" : "교정·요약에 \(vendor.name)를 사용합니다")
    }

    private func statusLine(_ status: AIVendorStatus) -> some View {
        HStack(spacing: 5) {
            if status.busy { ProgressView().controlSize(.mini).frame(width: 7, height: 7) }
            else {
                Circle().fill(status.tone == .ready ? SoriTheme.green : status.tone == .attention ? Color(hex: 0xC9962F) : SoriTheme.faint)
                    .frame(width: 6, height: 6)
            }
            Text(status.label + (status.model.map { " · " + $0 } ?? ""))
                .foregroundStyle(status.tone == .ready ? SoriTheme.green : SoriTheme.secondary)
                .lineLimit(1).truncationMode(.tail)
        }.font(.system(size: compact ? 11 : 12))
    }
}

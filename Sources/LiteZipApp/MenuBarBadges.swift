import SwiftUI

/// Lifetime usage in the menu bar footer: space saved and number of compressions as two
/// badges. They keep their full width, so nothing beside them can truncate the numbers.
struct UsageBadges: View {
    let bytesSaved: Int64
    let count: Int

    /// "0 KB" rather than a localized "Zero KB" or "0 bytes".
    private var saved: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytesSaved)
    }

    var body: some View {
        HStack(spacing: 6) {
            capsule(systemImage: "arrow.down.doc", text: saved).help("累计节省空间")
            capsule(systemImage: "doc.zipper", text: "\(count) 次").help("累计压缩次数")
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("累计节省 \(saved)，压缩 \(count) 次")
    }

    private func capsule(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium)).monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// The running version in the menu bar header. It turns green while a newer release is
/// known; clicking it then offers that release, and otherwise checks for one.
struct VersionCapsule: View {
    let version: String
    let available: String?
    let checking: Bool
    let action: () -> Void

    /// Dark enough for white text; the system green is too light for it.
    private static let updateGreen = Color(red: 0.08, green: 0.50, blue: 0.24)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let available {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 9, weight: .semibold))
                    Text("新版本 \(available)")
                } else {
                    Text(checking ? "检查中…" : "v\(version)")
                }
            }
            .font(.caption2.weight(.medium)).monospacedDigit().lineLimit(1)
            .foregroundStyle(available == nil ? Color.secondary : Color.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(available == nil ? Color.primary.opacity(0.06) : Self.updateGreen))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(checking && available == nil)
        .help(available.map { "LiteZip \($0) 已发布，点击更新" } ?? "当前版本 \(version)，点击检查更新")
        .accessibilityLabel(available.map { "有新版本 \($0)，点击更新" } ?? "当前版本 \(version)，点击检查更新")
    }
}

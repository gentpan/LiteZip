import SwiftUI

/// Shared look for the options panel's inputs: one rounded box holds the text and any
/// trailing control (unit menu, show-password eye), so every field has the same width.
/// The box, not the text field, shows focus, and only after the user clicks in.
struct FieldBox<Content: View>: View {
    let focused: Bool
    let content: Content
    @Environment(\.isEnabled) private var enabled

    init(focused: Bool, @ViewBuilder content: () -> Content) {
        self.focused = focused
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: focused ? 1.5 : 1))
            .opacity(enabled ? 1 : 0.55)
    }
}

/// The inner text field draws no ring of its own; the surrounding box shows focus.
private struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() } else { content }
    }
}

/// Volume size as a number with its unit inside the same box. The unit menu also offers
/// common sizes and "不分卷". The model keeps the "100 MB" text the core parser reads.
struct VolumeSizeField: View {
    @Binding var text: String
    let supported: Bool
    @State private var number = ""
    @State private var unit = "MB"
    @FocusState private var focused: Bool
    private static let presets = ["5 MB", "100 MB", "500 MB", "1 GB", "2 GB"]

    var body: some View {
        FieldBox(focused: focused) {
            TextField(supported ? "不分卷" : "此格式不支持分卷", text: $number)
                .textFieldStyle(.plain).monospacedDigit()
                .focused($focused).modifier(NoFocusRing())
                .accessibilityLabel("分卷大小")
            Menu {
                Picker("单位", selection: $unit) {
                    Text("MB").tag("MB")
                    Text("GB").tag("GB")
                }.pickerStyle(.inline)
                Section("常用大小") {
                    ForEach(Self.presets, id: \.self) { preset in Button(preset) { load(preset) } }
                }
                Divider()
                Button("不分卷") { number = "" }
            } label: {
                HStack(spacing: 3) {
                    Text(unit).font(.callout)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            // The button style keeps "MB ⌄" in order; a borderless menu moves the icon first.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("单位与常用大小。1 MB 按 1024² 字节计算")
            .accessibilityLabel("分卷单位：\(unit)")
        }
        .onAppear { load(text) }
        .onChange(of: text) { load($0) }
        .onChange(of: number) { _ in commit() }
        .onChange(of: unit) { _ in commit() }
    }

    private var composed: String { number.isEmpty ? "" : "\(number) \(unit)" }

    /// Splits "100 MB" (or a bare number, which the parser reads as MB) into the two parts.
    private func load(_ value: String) {
        guard value != composed else { return }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        number = String(trimmed.prefix { $0.isNumber || $0 == "." })
        let suffix = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).uppercased()
        if suffix.hasPrefix("G") { unit = "GB" } else if suffix.isEmpty || suffix.hasPrefix("M") { unit = "MB" }
    }

    private func commit() {
        let digits = number.filter { $0.isNumber || $0 == "." }
        guard digits == number else { number = digits; return }
        if text != composed { text = composed }
    }
}

struct PasswordInput: View {
    let placeholder: String
    let accessibilityLabel: String
    @Binding var text: String
    @Binding var visible: Bool
    let showsVisibilityButton: Bool
    @FocusState private var focused: Bool

    var body: some View {
        FieldBox(focused: focused) {
            Group {
                if visible { TextField(placeholder, text: $text) }
                else { SecureField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain).focused($focused).modifier(NoFocusRing())
            .accessibilityLabel(accessibilityLabel)
            if showsVisibilityButton {
                // The icon states what the field shows now: open eye = plaintext visible.
                Button { visible.toggle() } label: {
                    Image(systemName: visible ? "eye" : "eye.slash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).help(visible ? "隐藏密码" : "显示密码").accessibilityLabel(visible ? "隐藏密码" : "显示密码")
            }
        }
    }
}

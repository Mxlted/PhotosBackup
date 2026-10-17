import SwiftUI

enum BackupTheme {
    static let blue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.67, blue: 1, alpha: 1)
            : UIColor(red: 0.19, green: 0.35, blue: 0.70, alpha: 1)
    })
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemGroupedBackground
            : UIColor(red: 0.965, green: 0.965, blue: 0.95, alpha: 1)
    })
    static let secondaryBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let border = Color(uiColor: .separator).opacity(0.15)
    // White button labels need a deeper fill than the adaptive text/link tint.
    static let buttonFill = Color(red: 0.19, green: 0.35, blue: 0.70)
}

private struct BackupCard: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(BackupTheme.secondaryBackground,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(BackupTheme.border, lineWidth: 1))
    }
}

extension View {
    func backupCard(padding: CGFloat = 20) -> some View {
        modifier(BackupCard(padding: padding))
    }

    @ViewBuilder
    func backupListBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden).background(BackupTheme.background)
        } else {
            self
        }
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline).foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(isEnabled ? BackupTheme.buttonFill.opacity(configuration.isPressed ? 0.8 : 1)
                        : Color(uiColor: .systemGray))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Keeps card content legible when disabled while preserving a clear pressed state.
struct CardButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .saturation(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct FeatureIcon: View {
    let symbol: String
    var color: Color = BackupTheme.blue
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct AppMark: View {
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [BackupTheme.blue, BackupTheme.blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "photo.stack.fill")
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: BackupTheme.blue.opacity(0.16), radius: 20, y: 10)
        .accessibilityHidden(true)
    }
}

struct SafariTutorialCard: View {
    enum Scene {
        case signIn
        case enableExtension
        case connect
    }

    let scene: Scene

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "textformat.size")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                    Text(scene == .enableExtension ? "Safari Extensions" : "accounts.google.com")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .padding(10)

            Divider()

            Group {
                switch scene {
                case .signIn: signInScene
                case .enableExtension: extensionScene
                case .connect: connectScene
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Image(systemName: "chevron.backward")
                Spacer()
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "square.and.arrow.up")
                Spacer()
                Image(systemName: "book")
                Spacer()
                Image(systemName: "square.on.square")
            }
            .font(.body)
            .foregroundStyle(BackupTheme.blue)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(minHeight: 300)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.09), radius: 18, y: 8)
        .padding(.horizontal, 24)
    }

    private var signInScene: some View {
        VStack(spacing: 16) {
            Text("G").font(.system(size: 34, weight: .medium)).foregroundStyle(BackupTheme.blue)
            Text("Sign in").font(.title3.weight(.semibold))
            Text("Use your Google Account").font(.subheadline).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35))
                .frame(height: 44)
                .overlay(Text("Email or phone").font(.subheadline).foregroundStyle(.secondary), alignment: .leading)
                .padding(.horizontal, 30)
            Text("Next")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 24).padding(.vertical, 9)
                .background(BackupTheme.blue, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.vertical, 20)
    }

    private var extensionScene: some View {
        VStack(spacing: 10) {
            Text("Extensions").font(.headline)
            Text("Allow extensions to customize Safari.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                FeatureIcon(symbol: "photo.stack.fill", size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Photos Backup Connect")
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Website access allowed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)
                Spacer()
                Toggle("", isOn: .constant(true)).labelsHidden()
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            Text("Turn on the extension, then return to Safari.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 28)
    }

    private var connectScene: some View {
        VStack(spacing: 14) {
            HStack {
                FeatureIcon(symbol: "photo.stack.fill", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photos Backup").font(.subheadline.weight(.semibold))
                    Text("Safari Extension").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            Text("Ready to connect")
                .font(.title3.weight(.semibold))
            Text("We’ll securely send your sign-in to the Photos Backup app.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Label("Connect account", systemImage: "link")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(BackupTheme.blue, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
    }
}

struct SafariConnectionGuide: View {
    private let steps: [(String, String, String)] = [
        ("1", "Sign in and tap I agree", "Complete Google’s sign-in page."),
        ("2", "Open Safari’s extension menu", "Tap the puzzle-piece or page menu icon."),
        ("3", "Choose Photos Backup Connect", "Open our extension from the list."),
        ("4", "Tap Connect to App", "Wait for the green confirmation, then return.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "textformat.size").font(.caption.weight(.semibold))
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                    Text("accounts.google.com").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.caption).foregroundStyle(BackupTheme.blue)
            }
            .padding(10)
            Divider()
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.0)
                            .font(.caption.bold()).foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(BackupTheme.blue, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.1).font(.subheadline.weight(.semibold))
                            Text(item.2).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if index == steps.count - 1 {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 9)
                    if index < steps.count - 1 { Divider().padding(.leading, 38) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .frame(minHeight: 330)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.09), radius: 18, y: 8)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            FeatureIcon(symbol: symbol, size: 68)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Shared colors and surfaces for the location-link workflow.
enum LinkAppearance {
    static var accent: Color {
        adaptive(light: 0x14665C, dark: 0x85D9C7)
    }

    static var positive: Color {
        adaptive(light: 0x246647, dark: 0x91D8B0)
    }

    static var warning: Color {
        adaptive(light: 0x84500B, dark: 0xF1C47A)
    }

    static var secondaryText: Color {
        adaptive(light: 0x525F5D, dark: 0xAFBFBB)
    }

    static var page: Color {
        adaptive(light: 0xF2F5F3, dark: 0x101716)
    }

    static var surface: Color {
        adaptive(light: 0xFFFFFF, dark: 0x1B2523)
    }

    static var accentSurface: Color {
        adaptive(light: 0xE4F2ED, dark: 0x233D35)
    }

    static var warningSurface: Color {
        adaptive(light: 0xFFF3DD, dark: 0x392D1D)
    }

    // Keep the filled action dark in both appearances so its white label stays readable.
    static let actionFill = Color(red: 0.06, green: 0.34, blue: 0.30)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
            Color(
                uiColor: UIColor { traits in
                    let hex = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(
                        red: CGFloat((hex >> 16) & 0xFF) / 255,
                        green: CGFloat((hex >> 8) & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255,
                        alpha: 1
                    )
                })
        #else
            Color(
                red: Double((light >> 16) & 0xFF) / 255,
                green: Double((light >> 8) & 0xFF) / 255,
                blue: Double(light & 0xFF) / 255
            )
        #endif
    }
}

struct LinkIcon: View {
    let symbol: String
    var color: Color = LinkAppearance.accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct LinkActionButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(LinkActionLabelStyle())
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(prominent ? Color.white : LinkAppearance.accent)
            .background(
                prominent ? LinkAppearance.actionFill : LinkAppearance.accentSurface,
                in: RoundedRectangle(cornerRadius: 15)
            )
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(LinkAppearance.accent, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

private struct LinkActionLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            if !dynamicTypeSize.isAccessibilitySize {
                configuration.icon
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityHidden(true)
            }
            configuration.title
        }
    }
}

private struct LinkCardModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(LinkAppearance.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(
                        LinkAppearance.secondaryText.opacity(contrast == .increased ? 0.65 : 0.10),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func linkCard() -> some View {
        modifier(LinkCardModifier())
    }

    func linkListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(LinkAppearance.page)
            .tint(LinkAppearance.accent)
    }
}

import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

// Shared building blocks for the menu panel and Settings window.
// Modelled on Control Center modules: a filled circle means "on".

extension Color {
    static let moduleFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.6)
    })
    static let moduleStroke = Color.primary.opacity(0.06)
}

enum GlyphState { case off, on, busy, warning }

struct ModuleGlyph: View {
    let systemImage: String
    var state: GlyphState = .off
    var size: CGFloat = 30
    private var fill: Color {
        switch state {
        case .on: return .accentColor
        case .warning: return .orange
        case .off, .busy: return Color.primary.opacity(0.1)
        }
    }
    var body: some View {
        ZStack {
            Circle().fill(fill)
            if state == .busy {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(state == .off ? Color.primary : Color.white)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct ModuleTile<Detail: View, Accessory: View>: View {
    let title: String
    let glyph: String
    var state: GlyphState = .off
    let action: () -> Void
    @ViewBuilder var detail: Detail
    @ViewBuilder var accessory: Accessory
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ModuleGlyph(systemImage: glyph, state: state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    detail.font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                accessory.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(ModuleButtonStyle())
    }
}

struct ModuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.moduleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.moduleStroke))
            .overlay(Color.primary.opacity(configuration.isPressed ? 0.06 : 0).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
            .opacity(enabled ? 1 : 0.55)
    }
}

// Square Control Center-style button for the quick actions row.
struct QuickAction: View {
    let title: String
    let glyph: String
    var state: GlyphState = .off
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ModuleGlyph(systemImage: glyph, state: state)
                Text(title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.vertical, 10).frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(ModuleButtonStyle())
    }
}

// Battery, charging and network as reported by the phone, for the device header.
struct PhoneBadges: View {
    let status: PhoneStatus
    var body: some View {
        HStack(spacing: 6) {
            if let network = status.network, network != "none" {
                Image(systemName: network == "wifi" ? "wifi" : "antenna.radiowaves.left.and.right")
                    .accessibilityLabel(network == "wifi" ? "Wi-Fi" : "Cellular")
            }
            if let battery = status.battery {
                HStack(spacing: 3) {
                    Image(systemName: status.charging == true ? "battery.100percent.bolt"
                          : "battery.\([0, 25, 50, 75, 100].min { abs($0 - battery) < abs($1 - battery) } ?? 100)percent")
                    Text("\(battery)%").monospacedDigit()
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Battery \(battery) percent\(status.charging == true ? ", charging" : "")")
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

// Menu-item style row used for the bottom of the panel, like "Wi-Fi Settings…".
struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }.font(.system(size: 13)).padding(.horizontal, 9).frame(height: 24)
                .background(hovering ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 5).onHover { hovering = $0 }
    }
}

struct StatusDot: View {
    let online: Bool
    var body: some View {
        Circle().fill(online ? Color.green : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
    }
}

struct QRCard: View {
    let image: NSImage
    var size: CGFloat = 200
    var body: some View {
        Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            .frame(width: size, height: size).padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
    }
}

struct StepList: View {
    let steps: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.08), in: Circle())
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

func qrImage(_ data: Data) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator(); filter.message = data; filter.correctionLevel = "M"
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

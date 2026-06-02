import SwiftUI
import SpeakFlowCore

/// Schematic provider glyphs drawn natively, matching the design reference.
///
/// Shapes are non-branded originals: ChatGPT renders as a hexagonal knot,
/// Mistral as stacked bands, Deepgram as concentric sound rings.
struct ProviderLogo: View {
    let providerId: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Group {
            switch providerId {
            case ProviderId.chatGPT:
                ChatGPTGlyph(tint: tint)
            case ProviderId.deepgram:
                DeepgramGlyph(tint: tint)
            case ProviderId.mistral, ProviderId.mistralBatch:
                MistralGlyph(tint: tint)
            default:
                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ChatGPTGlyph: View {
    let tint: Color

    var body: some View {
        Canvas { ctx, canvasSize in
            let unit = min(canvasSize.width, canvasSize.height) / 32.0

            let bgRect = CGRect(x: 2 * unit, y: 2 * unit, width: 28 * unit, height: 28 * unit)
            ctx.fill(Path(ellipseIn: bgRect), with: .color(tint.opacity(0.14)))

            var hex = Path()
            hex.move(to: CGPoint(x: 10 * unit, y: 12 * unit))
            hex.addLine(to: CGPoint(x: 16 * unit, y: 8 * unit))
            hex.addLine(to: CGPoint(x: 22 * unit, y: 12 * unit))
            hex.addLine(to: CGPoint(x: 22 * unit, y: 20 * unit))
            hex.addLine(to: CGPoint(x: 16 * unit, y: 24 * unit))
            hex.addLine(to: CGPoint(x: 10 * unit, y: 20 * unit))
            hex.closeSubpath()
            ctx.stroke(hex, with: .color(tint), style: StrokeStyle(lineWidth: 1.6 * unit, lineJoin: .round))

            var spokes = Path()
            spokes.move(to: CGPoint(x: 16 * unit, y: 8 * unit))
            spokes.addLine(to: CGPoint(x: 16 * unit, y: 16 * unit))
            spokes.move(to: CGPoint(x: 16 * unit, y: 16 * unit))
            spokes.addLine(to: CGPoint(x: 10 * unit, y: 12 * unit))
            spokes.move(to: CGPoint(x: 16 * unit, y: 16 * unit))
            spokes.addLine(to: CGPoint(x: 22 * unit, y: 12 * unit))
            spokes.move(to: CGPoint(x: 16 * unit, y: 16 * unit))
            spokes.addLine(to: CGPoint(x: 16 * unit, y: 24 * unit))
            ctx.stroke(spokes, with: .color(tint), style: StrokeStyle(lineWidth: 1.2 * unit, lineCap: .round))
        }
    }
}

private struct MistralGlyph: View {
    let tint: Color

    var body: some View {
        Canvas { ctx, canvasSize in
            let unit = min(canvasSize.width, canvasSize.height) / 32.0
            let radius = 7 * unit

            let frame = Path(
                roundedRect: CGRect(x: 2 * unit, y: 2 * unit, width: 28 * unit, height: 28 * unit),
                cornerRadius: radius
            )
            ctx.fill(frame, with: .color(tint.opacity(0.14)))

            let bandRects: [(CGRect, Double)] = [
                (CGRect(x: 7 * unit, y: 8 * unit, width: 18 * unit, height: 3 * unit), 1.0),
                (CGRect(x: 7 * unit, y: 13 * unit, width: 18 * unit, height: 3 * unit), 0.7),
                (CGRect(x: 7 * unit, y: 18 * unit, width: 18 * unit, height: 3 * unit), 0.45),
                (CGRect(x: 7 * unit, y: 23 * unit, width: 11 * unit, height: 3 * unit), 0.25),
            ]
            for (rect, alpha) in bandRects {
                ctx.fill(Path(rect), with: .color(tint.opacity(alpha)))
            }
        }
    }
}

private struct DeepgramGlyph: View {
    let tint: Color

    var body: some View {
        Canvas { ctx, canvasSize in
            let unit = min(canvasSize.width, canvasSize.height) / 32.0
            let radius = 7 * unit

            let frame = Path(
                roundedRect: CGRect(x: 2 * unit, y: 2 * unit, width: 28 * unit, height: 28 * unit),
                cornerRadius: radius
            )
            ctx.fill(frame, with: .color(tint.opacity(0.14)))

            let dotRect = CGRect(
                x: 13 * unit, y: 13 * unit, width: 6 * unit, height: 6 * unit
            )
            ctx.fill(Path(ellipseIn: dotRect), with: .color(tint))

            var inner = Path()
            inner.addArc(
                center: CGPoint(x: 16 * unit, y: 16 * unit),
                radius: 5.5 * unit,
                startAngle: .degrees(180),
                endAngle: .degrees(0),
                clockwise: false
            )
            ctx.stroke(
                inner,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round)
            )

            var outer = Path()
            outer.addArc(
                center: CGPoint(x: 16 * unit, y: 16 * unit),
                radius: 9 * unit,
                startAngle: .degrees(180),
                endAngle: .degrees(0),
                clockwise: false
            )
            ctx.stroke(
                outer,
                with: .color(tint.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.4 * unit, lineCap: .round)
            )
        }
    }
}

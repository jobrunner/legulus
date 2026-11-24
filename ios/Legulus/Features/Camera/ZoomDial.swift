import SwiftUI

/// The zoom dial over the shutter, after the system camera: a dark
/// half-disc across the screen, a fine scale along its edge that turns
/// under a fixed yellow pointer, the lenses as long ticks with their
/// factor, and the current factor in yellow under the pointer.
///
/// Only the picture: dragging is handled by the zoom control in
/// `CameraView`, which stays while it swaps lens buttons and dial, so a
/// drag that starts on the buttons goes on on the dial. VoiceOver zooms
/// through that control as one adjustable element.
struct ZoomDial: View {
    let scale: ZoomScale
    let factor: CGFloat

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 150
    /// Distance of the labels from the edge of the disc.
    @ScaledMetric(relativeTo: .body) private var labelInset: CGFloat = 36

    /// Radius of the disc relative to its width: wide enough that the
    /// disc runs off both sides of the screen.
    private let radiusRatio: CGFloat = 0.62
    /// Angle the whole scale (smallest to largest factor) spans.
    private let scaleAngle: Angle = .degrees(150)
    /// Fine ticks over the whole scale.
    private let tickCount = 60
    private let tickWidth: CGFloat = 1
    private let lensTickWidth: CGFloat = 2
    /// Lens labels this close to the pointer give way to the current value.
    private let labelGap: Angle = .degrees(9)

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let radius = size.width * radiusRatio
        let centre = CGPoint(x: size.width / 2, y: AppSpacing.sm + radius)
        let current = scale.dialPosition(factor)

        let disc = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        context.fill(disc, with: .color(AppColor.cameraScrim))

        func angle(_ position: CGFloat) -> CGFloat {
            (position - current) * scaleAngle.radians
        }
        func point(_ angle: CGFloat, inset: CGFloat) -> CGPoint {
            let distance = radius - inset
            return CGPoint(x: centre.x + sin(angle) * distance, y: centre.y - cos(angle) * distance)
        }
        func tick(at position: CGFloat, length: CGFloat, width: CGFloat, color: Color) {
            let tickAngle = angle(position)
            guard abs(tickAngle) < .pi / 2 else { return }
            var path = Path()
            path.move(to: point(tickAngle, inset: AppSpacing.xs))
            path.addLine(to: point(tickAngle, inset: AppSpacing.xs + length))
            context.stroke(path, with: .color(color), lineWidth: width)
        }
        func label(_ text: String, at position: CGFloat, color: Color, font: Font) {
            let labelAngle = angle(position)
            guard abs(labelAngle) < .pi / 2, abs(labelAngle) > labelGap.radians else { return }
            var layer = context
            let spot = point(labelAngle, inset: labelInset)
            layer.translateBy(x: spot.x, y: spot.y)
            layer.rotate(by: .radians(labelAngle))
            layer.draw(Text(text).font(font).foregroundStyle(color), at: .zero)
        }

        for index in 0 ... tickCount {
            tick(at: CGFloat(index) / CGFloat(tickCount), length: AppSpacing.sm, width: tickWidth, color: .white.opacity(0.55))
        }
        let marked = scale.lensStops + [scale.maxFactor]
        for stop in marked {
            let position = scale.dialPosition(stop)
            tick(at: position, length: AppSpacing.md, width: lensTickWidth, color: .white)
            label(ZoomScale.number(scale.displayFactor(stop)), at: position, color: .white, font: AppFont.footnote.weight(.semibold))
        }

        // Fixed pointer at the top edge and the current value under it.
        let top = CGPoint(x: centre.x, y: centre.y - radius + AppSpacing.xs)
        var pointer = Path()
        pointer.move(to: CGPoint(x: top.x - AppSpacing.xs, y: top.y))
        pointer.addLine(to: CGPoint(x: top.x + AppSpacing.xs, y: top.y))
        pointer.addLine(to: CGPoint(x: top.x, y: top.y + AppSpacing.sm))
        pointer.closeSubpath()
        context.fill(pointer, with: .color(AppColor.cameraActive))
        context.draw(
            Text(ZoomScale.text(scale.displayFactor(factor)))
                .font(AppFont.headline.monospacedDigit())
                .foregroundStyle(AppColor.cameraActive),
            at: point(0, inset: labelInset)
        )
    }
}

private struct ZoomDialPreview: View {
    var body: some View {
        ZoomDial(
            scale: ZoomScale(deviceType: .builtInTripleCamera, switchOverFactors: [2, 6], minFactor: 1, maxFactor: 15),
            factor: 4
        )
        .background(.gray)
    }
}

#Preview("Zoomrad") {
    ZoomDialPreview()
}

#Preview("Zoomrad AX5") {
    ZoomDialPreview()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Zoomrad Dark") {
    ZoomDialPreview()
        .preferredColorScheme(.dark)
}

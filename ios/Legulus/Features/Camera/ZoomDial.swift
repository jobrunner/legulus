import SwiftUI

/// The zoom dial over the shutter, after the system camera in video
/// mode: a dark disc across the screen, a fine scale along its edge that turns
/// under a fixed yellow pointer, the snap stops as long ticks with their
/// factor, and the current factor in yellow under the pointer.
///
/// Only the picture: dragging is handled by the zoom control in
/// `CameraView`, which stays while it swaps lens buttons and dial, so a
/// drag that starts on the buttons goes on on the dial. VoiceOver zooms
/// through that control as one adjustable element.
struct ZoomDial: View {
    let scale: ZoomScale
    let factor: CGFloat
    /// The camera draws the disc itself, as one arch down to the screen
    /// edge (`DialArch`), so it is not darkened twice.
    var drawsDisc = true

    /// Radius of the disc relative to its width: the arc of the video
    /// mode, which reaches both screen edges a short way down.
    static let radiusRatio: CGFloat = 0.55
    /// Gap between the top of the view and the top of the disc.
    static let discTop = AppSpacing.sm

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 170
    /// Distance of the labels from the edge of the disc.
    @ScaledMetric(relativeTo: .body) private var labelInset: CGFloat = 44

    /// Turn per doubling of the factor; fixed, as in the system camera,
    /// so a short range takes only part of the arc.
    private let anglePerDoubling: Angle = .degrees(40)
    /// Angle between two fine ticks.
    private let tickStep: Angle = .degrees(2.4)
    private let tickWidth: CGFloat = 1
    private let markWidth: CGFloat = 2
    /// Snap labels this close to the pointer give way to the current value.
    private let labelGap: Angle = .degrees(10)

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let radius = size.width * Self.radiusRatio
        let centre = CGPoint(x: size.width / 2, y: Self.discTop + radius)

        if drawsDisc {
            let disc = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            context.fill(disc, with: .color(AppColor.cameraScrim))
        }

        // Angle of a factor from the pointer, logarithmic.
        func angle(_ deviceFactor: CGFloat) -> CGFloat {
            log2(deviceFactor / factor) * anglePerDoubling.radians
        }
        func point(_ angle: CGFloat, inset: CGFloat) -> CGPoint {
            let distance = radius - inset
            return CGPoint(x: centre.x + sin(angle) * distance, y: centre.y - cos(angle) * distance)
        }
        func tick(at tickAngle: CGFloat, length: CGFloat, width: CGFloat, color: Color) {
            guard abs(tickAngle) < .pi / 2 else { return }
            var path = Path()
            path.move(to: point(tickAngle, inset: AppSpacing.xs))
            path.addLine(to: point(tickAngle, inset: AppSpacing.xs + length))
            context.stroke(path, with: .color(color), lineWidth: width)
        }
        func label(_ text: String, at labelAngle: CGFloat) {
            guard abs(labelAngle) < .pi / 2, abs(labelAngle) > labelGap.radians else { return }
            var layer = context
            let spot = point(labelAngle, inset: labelInset)
            layer.translateBy(x: spot.x, y: spot.y)
            layer.rotate(by: .radians(labelAngle))
            layer.draw(Text(text).font(AppFont.headline).foregroundStyle(.white), at: .zero)
        }

        // Fine ticks over the optical range only.
        let first = angle(scale.minFactor)
        let last = angle(scale.maxFactor)
        var tickAngle = first
        while tickAngle <= last + 0.001 {
            tick(at: tickAngle, length: AppSpacing.sm, width: tickWidth, color: .white.opacity(0.5))
            tickAngle += tickStep.radians
        }
        // The snap stops carry long ticks and their factor.
        let marked = scale.snapStops.isEmpty ? scale.lensStops + [scale.maxFactor] : scale.snapStops
        for stop in marked {
            tick(at: angle(stop), length: AppSpacing.lg, width: markWidth, color: .white)
            label(ZoomScale.number(scale.displayFactor(stop)), at: angle(stop))
        }

        // Fixed pointer at the top edge and the current value under it.
        let top = CGPoint(x: centre.x, y: centre.y - radius + AppSpacing.xs)
        var pointer = Path()
        pointer.move(to: CGPoint(x: top.x - AppSpacing.xs, y: top.y))
        pointer.addLine(to: CGPoint(x: top.x + AppSpacing.xs, y: top.y))
        pointer.addLine(to: CGPoint(x: top.x, y: top.y + AppSpacing.md))
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

/// The shade behind the open zoom dial in the camera: the dial's disc on
/// top, running straight down to the bottom edge like an upside-down U,
/// so the controls under the dial sit on the same shade as the dial.
struct DialArch: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width * ZoomDial.radiusRatio
        let centre = CGPoint(x: rect.midX, y: rect.minY + ZoomDial.discTop + radius)
        var path = Path()
        path.addArc(center: centre, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: centre.x + radius, y: rect.maxY))
        path.addLine(to: CGPoint(x: centre.x - radius, y: rect.maxY))
        path.closeSubpath()
        return path
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

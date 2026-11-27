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
struct ZoomDial: View, Animatable {
    @Environment(\.colorSchemeContrast) private var contrast
    let scale: ZoomScale
    /// Animatable: a jump of the zoom (lens button) turns the dial over
    /// instead of snapping, so the numbers do not pop.
    var factor: CGFloat
    /// The camera draws the disc itself, as one arch down to the screen
    /// edge (`DialArch`), so it is not darkened twice.
    var drawsDisc = true
    /// In landscape the labels stand upright to the horizon by this turn;
    /// in portrait (zero) they follow the arc.
    var uprightRotation: Angle = .zero

    /// Radius of the disc relative to its width: the arc of the video
    /// mode, which reaches both screen edges a short way down.
    static let radiusRatio: CGFloat = 0.55
    /// Gap between the top of the view and the top of the disc.
    static let discTop = AppSpacing.sm

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 170
    /// Distance of the labels from the edge of the disc.
    @ScaledMetric(relativeTo: .body) private var labelInset: CGFloat = 35

    /// Turn per doubling of the factor; fixed, as in the system camera,
    /// so a short range takes only part of the arc.
    private let anglePerDoubling: Angle = .degrees(40)
    /// Angle between two fine ticks, roughly; each section between two
    /// snap stops is divided evenly, so every stop sits on a tick.
    private let tickStep: Angle = .degrees(2.4)
    /// All ticks are equally long; the snap stops are wider and white.
    private let tickLength = AppSpacing.md
    private let tickWidth: CGFloat = 1
    private let markWidth: CGFloat = 2
    /// The pointer: narrow, its length the tick length times the golden ratio.
    private let pointerWidth: CGFloat = 6
    private let goldenRatio: CGFloat = 1.618
    /// Snap labels this close to the pointer give way to the current value,
    /// fading out over `labelFade` before.
    private let labelGap: Angle = .degrees(10)
    private let labelFade: Angle = .degrees(8)

    var animatableData: CGFloat {
        get { factor }
        set { factor = newValue }
    }

    /// Tick angles from the first to the last mark: each section between
    /// two marks divided into equal parts of about `step`, so every mark
    /// is a tick.
    static func tickAngles(marks: [CGFloat], step: CGFloat) -> [CGFloat] {
        let sorted = Array(Set(marks)).sorted()
        guard let first = sorted.first, step > 0 else { return [] }
        var angles = [first]
        for (start, end) in zip(sorted, sorted.dropFirst()) {
            let parts = max(1, Int(((end - start) / step).rounded()))
            for part in 1 ... parts {
                angles.append(start + (end - start) * CGFloat(part) / CGFloat(parts))
            }
        }
        return angles
    }

    /// Length of a tick by its distance from the pointer, as a share of
    /// the full length: none right under the pointer, short for the two
    /// neighbours, full for all others.
    static func tickLengthScale(distance: CGFloat, step: CGFloat) -> CGFloat {
        let distance = abs(distance)
        if distance < step * 0.5 { return 0 }
        if distance < step * 1.5 { return neighbourLengthShare }
        return 1
    }

    /// Length of the ticks beside the pointer, as a share of a full tick.
    static let neighbourLengthShare: CGFloat = 0.3

    /// Opacity of a snap label by its angle from the pointer: hidden within
    /// `gap`, fading in over `fade`, full beyond.
    static func labelOpacity(distance: CGFloat, gap: CGFloat, fade: CGFloat) -> CGFloat {
        let beyond = abs(distance) - gap
        guard beyond > 0 else { return 0 }
        return fade > 0 ? min(beyond / fade, 1) : 1
    }

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
            // The numbers are text on the camera picture: a ground they
            // stay legible on, stronger with Increase Contrast.
            let ground = contrast == .increased ? AppColor.cameraScrimStrong : AppColor.cameraScrimText
            context.fill(disc, with: .color(ground))
        }

        // Angle of a factor from the pointer, logarithmic.
        func angle(_ deviceFactor: CGFloat) -> CGFloat {
            log2(deviceFactor / factor) * anglePerDoubling.radians
        }
        func point(_ angle: CGFloat, inset: CGFloat) -> CGPoint {
            let distance = radius - inset
            return CGPoint(x: centre.x + sin(angle) * distance, y: centre.y - cos(angle) * distance)
        }
        // Every tick ends at the same inner line; a shortened one loses its
        // outer part, where the pointer is wide, so the pointer lies over
        // the scale without touching it.
        let innerInset = AppSpacing.xs + tickLength
        func tick(at tickAngle: CGFloat, length: CGFloat, width: CGFloat, color: Color) {
            guard abs(tickAngle) < .pi / 2 else { return }
            var path = Path()
            path.move(to: point(tickAngle, inset: innerInset - length))
            path.addLine(to: point(tickAngle, inset: innerInset))
            context.stroke(path, with: .color(color), lineWidth: width)
        }
        func label(_ text: String, at labelAngle: CGFloat) {
            let opacity = Self.labelOpacity(distance: labelAngle, gap: labelGap.radians, fade: labelFade.radians)
            guard abs(labelAngle) < .pi / 2, opacity > 0 else { return }
            var layer = context
            layer.opacity = opacity
            let spot = point(labelAngle, inset: labelInset)
            layer.translateBy(x: spot.x, y: spot.y)
            layer.rotate(by: uprightRotation == .zero ? .radians(labelAngle) : uprightRotation)
            layer.draw(Text(text).font(AppFont.headline).foregroundStyle(.white), at: .zero)
        }

        // The scale over the optical range only; the snap stops (white,
        // wider, with their factor) sit on ticks of the even division.
        let stops = scale.snapStops.isEmpty ? scale.lensStops + [scale.maxFactor] : scale.snapStops
        let stopAngles = stops.map(angle)
        let ticks = Self.tickAngles(
            marks: [angle(scale.minFactor), angle(scale.maxFactor)] + stopAngles,
            step: tickStep.radians
        )
        for tickAngle in ticks {
            let isStop = stopAngles.contains { abs($0 - tickAngle) < 1e-6 }
            let length = tickLength * Self.tickLengthScale(distance: tickAngle, step: tickStep.radians)
            guard length > 0 else { continue }
            tick(
                at: tickAngle,
                length: length,
                width: isStop ? markWidth : tickWidth,
                color: isStop ? .white : .white.opacity(0.5)
            )
        }
        for (stop, stopAngle) in zip(stops, stopAngles) {
            label(ZoomScale.number(scale.displayFactor(stop)), at: stopAngle)
        }

        // Fixed pointer from the top edge, where the tick under it is left out.
        let top = CGPoint(x: centre.x, y: centre.y - radius + AppSpacing.xs)
        var pointer = Path()
        pointer.move(to: CGPoint(x: top.x - pointerWidth / 2, y: top.y))
        pointer.addLine(to: CGPoint(x: top.x + pointerWidth / 2, y: top.y))
        pointer.addLine(to: CGPoint(x: top.x, y: top.y + tickLength * goldenRatio))
        pointer.closeSubpath()
        context.fill(pointer, with: .color(AppColor.cameraActive))
        // Turned upright in landscape the value runs lengthwise; it moves
        // inward by its own extent so it stays clear of the pointer tip.
        let value = context.resolve(
            Text(ZoomScale.text(scale.displayFactor(factor)))
                .font(AppFont.headline.monospacedDigit())
                .foregroundStyle(AppColor.cameraActive)
        )
        let valueSize = value.measure(in: size)
        let radialExtent = uprightRotation == .zero ? valueSize.height : valueSize.width
        let pointerTip = AppSpacing.xs + tickLength * goldenRatio
        var valueLayer = context
        let valueSpot = point(0, inset: max(labelInset, pointerTip + AppSpacing.xs + radialExtent / 2))
        valueLayer.translateBy(x: valueSpot.x, y: valueSpot.y)
        valueLayer.rotate(by: uprightRotation)
        valueLayer.draw(value, at: .zero)
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

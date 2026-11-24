import SwiftUI

/// The zoom dial over the shutter, as in the system camera: an arc with
/// a scale that turns under a fixed pointer, marks at the lenses and the
/// current factor in the middle. Dragging sideways zooms.
///
/// It is a visual aid for the pinch. VoiceOver zooms through the zoom
/// control in `CameraView`, which wraps the dial and the lens buttons
/// into one adjustable element.
struct ZoomDial: View {
    let scale: ZoomScale
    let factor: CGFloat
    let onChange: (CGFloat) -> Void
    /// Any touch, so the owner can keep the dial on screen.
    let onInteraction: () -> Void

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 88
    /// Dial position at the start of the current drag.
    @State private var dragStart: CGFloat?
    @State private var width: CGFloat = 1

    /// Part of the whole dial (0…1) one screen width of dragging covers.
    private let dragSpan: CGFloat = 0.8
    /// Angle from the pointer to the edge of the visible arc.
    private let visibleAngle: Angle = .degrees(42)
    /// Number of small ticks over the whole scale.
    private let tickCount = 40
    private let tickWidth: CGFloat = 1.5

    var body: some View {
        VStack(spacing: AppSpacing.xxs) {
            Text(ZoomScale.text(scale.displayFactor(factor)))
                .font(AppFont.bodyEmphasized.monospacedDigit())
                .foregroundStyle(AppColor.warning)
            Canvas { context, size in
                drawScale(in: &context, size: size)
            }
            .frame(height: height)
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .gesture(drag)
        .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onInteraction()
                let start = dragStart ?? scale.dialPosition(factor)
                if dragStart == nil { dragStart = start }
                // Dragging to the left turns the scale towards higher factors.
                let position = start - value.translation.width / width * dragSpan
                onChange(scale.deviceFactor(dialPosition: position))
            }
            .onEnded { _ in
                dragStart = nil
                onInteraction()
            }
    }

    private func drawScale(in context: inout GraphicsContext, size: CGSize) {
        // Arc centre below the view, so the top of the circle is the dial.
        let radius = size.width * 0.9
        let centre = CGPoint(x: size.width / 2, y: radius + AppSpacing.md)
        let current = scale.dialPosition(factor)
        let span = visibleAngle.radians * 2.5

        func point(at position: CGFloat, inset: CGFloat) -> CGPoint? {
            let angle = (position - current) * span
            guard abs(angle) <= visibleAngle.radians else { return nil }
            let distance = radius - inset
            return CGPoint(x: centre.x + sin(angle) * distance, y: centre.y - cos(angle) * distance)
        }

        for index in 0 ... tickCount {
            let position = CGFloat(index) / CGFloat(tickCount)
            guard let outer = point(at: position, inset: 0), let inner = point(at: position, inset: AppSpacing.sm) else { continue }
            var tick = Path()
            tick.move(to: outer)
            tick.addLine(to: inner)
            context.stroke(tick, with: .color(.white.opacity(0.7)), lineWidth: tickWidth)
        }
        for stop in scale.lensStops {
            let position = scale.dialPosition(stop)
            guard let outer = point(at: position, inset: 0), let inner = point(at: position, inset: AppSpacing.lg),
                  let label = point(at: position, inset: AppSpacing.xxl)
            else { continue }
            var tick = Path()
            tick.move(to: outer)
            tick.addLine(to: inner)
            context.stroke(tick, with: .color(.white), lineWidth: tickWidth * 2)
            context.draw(
                Text(ZoomScale.text(scale.displayFactor(stop))).font(AppFont.caption).foregroundStyle(.white),
                at: label
            )
        }
        // The fixed pointer at the top.
        var pointer = Path()
        pointer.move(to: CGPoint(x: size.width / 2, y: centre.y - radius - AppSpacing.xxs))
        pointer.addLine(to: CGPoint(x: size.width / 2, y: centre.y - radius + AppSpacing.lg))
        context.stroke(pointer, with: .color(AppColor.warning), lineWidth: tickWidth * 2)
    }
}

private struct ZoomDialPreview: View {
    @State private var factor: CGFloat = 2

    var body: some View {
        ZoomDial(
            scale: ZoomScale(deviceType: .builtInTripleCamera, switchOverFactors: [2, 6], minFactor: 1, maxFactor: 15),
            factor: factor,
            onChange: { factor = $0 },
            onInteraction: {}
        )
        .padding()
        .background(.black)
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

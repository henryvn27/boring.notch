// Adapted from Clicky (MIT) at commit a80fa80721a8aebe51a170a7780705024ebc6e46.
// Copyright (c) 2026 Farza.

import AppKit
import SwiftUI

@MainActor
final class AssistantPointerOverlayController {
    static let shared = AssistantPointerOverlayController()

    private var panels: [NSPanel] = []
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ points: [AssistantPointCommand], on displayFrame: CGRect) {
        dismiss()

        panels = points.prefix(1).map { point in
            let panelSize = CGSize(width: 220, height: 74)
            let center = CGPoint(
                x: displayFrame.minX + point.x * displayFrame.width,
                y: displayFrame.maxY - point.y * displayFrame.height
            )
            let panel = NSPanel(
                contentRect: CGRect(
                    x: center.x - panelSize.width / 2,
                    y: center.y - panelSize.height / 2,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = NSHostingView(
                rootView: AssistantPointerMarker(label: point.label)
            )
            panel.orderFrontRegardless()
            return panel
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

private struct AssistantPointerMarker: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.black.opacity(0.82), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
                .offset(y: -24)

            ZStack {
                Circle()
                    .stroke(Color.effectiveAccent.opacity(0.45), lineWidth: 2)
                    .frame(width: 28, height: 28)
                    .scaleEffect(appeared && !reduceMotion ? 1.45 : 1)
                    .opacity(appeared && !reduceMotion ? 0 : 1)
                Circle()
                    .fill(Color.effectiveAccent)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: Color.effectiveAccent.opacity(0.6), radius: 7)
            }
            .offset(y: 9)
        }
        .frame(width: 220, height: 74)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1).repeatCount(5, autoreverses: false)) {
                appeared = true
            }
        }
        .accessibilityHidden(true)
    }
}

//
//  ScanningView.swift
//  Broom
//

import CoreGraphics
import Foundation
import SwiftUI

/// Shown while a scan runs: a ring that fills in as top-level folders are counted, plus live totals.
struct ScanningView: View {
    let session: ScanSession
    let onCancel: () -> Void

    var body: some View {
        let snapshot = session.snapshot

        VStack(spacing: 28) {
            Spacer(minLength: 20)

            Text("Scanning “\(session.target.name)”")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { timeline in
                    Canvas { context, size in
                        ScanRingRenderer.draw(
                            snapshot: snapshot,
                            time: timeline.date.timeIntervalSince(session.startDate),
                            size: size,
                            in: &context
                        )
                    }
                }

                VStack(spacing: 6) {
                    Text(snapshot.bytes.byteString)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("\(snapshot.files.formatted()) files")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                    TimelineView(.periodic(from: session.startDate, by: 0.1)) { timeline in
                        Text(elapsedText(at: timeline.date))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .foregroundStyle(Theme.primaryText)
            }
            .frame(width: 400, height: 400)

            Text(snapshot.currentPath.isEmpty ? " " : snapshot.currentPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)

            Button {
                onCancel()
            } label: {
                Text("Stop")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 22)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.panelStrong))
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(date.timeIntervalSince(session.startDate), 0)
        return "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"
    }
}

/// Draws the scanning ring: one wedge per top-level folder, sized by what's been counted so far,
/// with a light sweeping around the outside.
enum ScanRingRenderer {
    static func draw(snapshot: ScanSnapshot, time: TimeInterval, size: CGSize, in context: inout GraphicsContext) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2 - 6
        let inner = outer * 0.62
        let fullCircle = SunburstLayout.fullCircle

        // Track.
        let track = SunburstRenderer.sector(center: center, inner: inner, outer: outer, start: 0, end: fullCircle - 1e-6)
        context.fill(track, with: .color(Color.white.opacity(0.04)))

        // Wedges grow as bytes are found. They fill the ring proportionally, so the ring reads as
        // "where the space is" rather than as a progress bar.
        let total = snapshot.topFolders.reduce(Int64(0)) { $0 + $1.bytes }
        if total > 0 {
            // Ease the ring open over the first second so it doesn't pop in.
            let reveal = min(time / 1.0, 1)
            var angle = 0.0
            for folder in snapshot.topFolders where folder.bytes > 0 {
                let span = Double(folder.bytes) / Double(total) * fullCircle * reveal
                if span > 0.004 {
                    let path = SunburstRenderer.sector(center: center, inner: inner, outer: outer, start: angle, end: angle + span)
                    let color = SunburstPalette.color(midAngle: angle + span / 2, depth: 0, isDirectory: true)
                    context.fill(path, with: .color(color))
                    context.stroke(path, with: .color(Theme.chartSeparator), lineWidth: 1)
                }
                angle += span
            }
        }

        // A soft highlight orbiting the ring.
        let sweepStart = (time * 1.6).truncatingRemainder(dividingBy: fullCircle)
        for step in 0..<12 {
            let fraction = Double(step) / 12
            let start = sweepStart - fraction * 0.9
            let end = start + 0.08
            let path = SunburstRenderer.sector(center: center, inner: outer + 4, outer: outer + 6, start: start, end: end)
            context.fill(path, with: .color(Theme.accent.opacity(0.6 * (1 - fraction))))
        }

        // Inner disc.
        let disc = Path(ellipseIn: CGRect(x: center.x - inner + 10, y: center.y - inner + 10, width: (inner - 10) * 2, height: (inner - 10) * 2))
        context.fill(disc, with: .radialGradient(
            Gradient(colors: [Color(white: 0.2), Color(white: 0.115)]),
            center: center, startRadius: 0, endRadius: inner
        ))
        context.stroke(disc, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
    }
}

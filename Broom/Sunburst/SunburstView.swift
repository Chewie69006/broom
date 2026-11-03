//
//  SunburstView.swift
//  Broom
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The interactive sunburst. Hover a wedge to see what it is, click a folder to zoom in, click the
/// center to go up, drag a wedge to the collector.
struct SunburstChart: View {
    let browser: BrowserModel

    @State private var hover: ChartHover? = nil
    /// The node the chart last reported as hovered, so leaving the chart only clears our own hover.
    @State private var chartHoveredNode: FileNode? = nil

    private enum ChartHover: Equatable {
        case center
        case segment(ring: Int, index: Int)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = browser.layout
            let geometry = SunburstGeometry(size: proxy.size, ringCount: layout.ringCount)
            let transition = browser.transition
            let highlight = highlightRange(in: layout)
            let isCenterHovered = hover == .center && browser.canGoUp
            // Worked out ahead of time so the drag handler only captures a URL.
            let dragURL = chartHoveredNode.map { browser.url(for: $0) }

            ZStack {
                TimelineView(.animation(minimumInterval: nil, paused: transition == nil)) { timeline in
                    let frame = transition.map { $0.frame(at: $0.progress(at: timeline.date)) }
                        ?? SunburstTransition.Frame.identity
                    Canvas { context, _ in
                        SunburstRenderer.draw(
                            layout: layout, geometry: geometry, frame: frame,
                            highlight: highlight, isCenterHovered: isCenterHovered, in: &context
                        )
                    }
                }

                ChartCenterLabel(content: centerContent(in: layout), holeRadius: geometry.holeRadius)
                    .frame(width: geometry.holeRadius * 1.6, height: geometry.holeRadius * 1.5)
                    .position(geometry.center)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                updateHover(phase, geometry: geometry, layout: layout)
            }
            .onTapGesture(coordinateSpace: .local) { location in
                handleTap(at: location, geometry: geometry, layout: layout)
            }
            .onDrag {
                guard let dragURL else { return NSItemProvider() }
                return NSItemProvider(object: dragURL as NSURL)
            } preview: {
                if let node = chartHoveredNode {
                    DragPreview(node: node, browser: browser)
                }
            }
            .contextMenu {
                if let node = chartHoveredNode {
                    ItemMenuItems(node: node, browser: browser)
                }
            }
        }
        .onChange(of: browser.current) {
            hover = nil
            chartHoveredNode = nil
        }
    }

    // MARK: - Interaction

    private func hitTest(_ point: CGPoint, geometry: SunburstGeometry, layout: SunburstLayout) -> ChartHover? {
        let polar = geometry.polar(of: point)
        if polar.radius < geometry.holeRadius { return .center }
        guard let depth = geometry.depth(atRadius: polar.radius) else { return nil }
        let ring = Int(depth)
        guard let index = layout.hitTest(angle: polar.angle, ring: ring) else { return nil }
        return .segment(ring: ring, index: index)
    }

    private func updateHover(_ phase: HoverPhase, geometry: SunburstGeometry, layout: SunburstLayout) {
        var newHover: ChartHover?
        if case .active(let point) = phase {
            newHover = hitTest(point, geometry: geometry, layout: layout)
        }
        var node: FileNode?
        if case .segment(let ring, let index) = newHover {
            node = layout.segment(ring: ring, index: index)?.node
        }

        if hover != newHover { hover = newHover }
        if chartHoveredNode !== node {
            // Only replace a hover the chart set itself, or none at all.
            if browser.hovered == nil || browser.hovered === chartHoveredNode {
                browser.hovered = node
            }
            chartHoveredNode = node
        }
    }

    private func handleTap(at point: CGPoint, geometry: SunburstGeometry, layout: SunburstLayout) {
        switch hitTest(point, geometry: geometry, layout: layout) {
        case .center:
            browser.goUp()
        case .segment(let ring, let index):
            guard let segment = layout.segment(ring: ring, index: index) else { return }
            if let node = segment.node {
                browser.activate(node)
            } else if segment.owner !== browser.current {
                // "Smaller items" stand for the rest of their folder, so zoom into that folder.
                browser.open(segment.owner)
            }
        case nil:
            break
        }
    }

    // MARK: - Display

    private func highlightRange(in layout: SunburstLayout) -> SunburstRenderer.Highlight? {
        var position: (ring: Int, index: Int)?
        if case .segment(let ring, let index) = hover {
            position = (ring, index)
        } else if let node = browser.hovered ?? browser.selected {
            position = layout.position(of: node)
        }
        guard let position, let segment = layout.segment(ring: position.ring, index: position.index) else {
            return nil
        }
        return SunburstRenderer.Highlight(ring: segment.depth, start: segment.startAngle, end: segment.endAngle)
    }

    private func centerContent(in layout: SunburstLayout) -> ChartCenterLabel.Content {
        if case .segment(let ring, let index) = hover, let segment = layout.segment(ring: ring, index: index) {
            if let node = segment.node {
                return .init(node: node, hint: nil)
            }
            return .init(
                title: "\(segment.hiddenCount.formatted()) smaller items",
                size: segment.hiddenSize, detail: "in \(segment.owner.name)", hint: nil
            )
        }
        if hover == .center, let parent = browser.current.parent {
            return .init(node: browser.current, hint: "Back to \(parent.name)")
        }
        if let node = browser.hovered {
            return .init(node: node, hint: nil)
        }
        return .init(node: browser.current, hint: nil)
    }
}

// MARK: - Drawing

enum SunburstRenderer {
    /// A wedge and everything outside it (its contents), drawn brighter.
    struct Highlight {
        let ring: Int
        let start: Double
        let end: Double

        func contains(_ segment: SunburstSegment) -> Bool {
            segment.depth >= ring && segment.startAngle >= start - 1e-9 && segment.endAngle <= end + 1e-9
        }
    }

    static func draw(
        layout: SunburstLayout,
        geometry: SunburstGeometry,
        frame: SunburstTransition.Frame,
        highlight: Highlight?,
        isCenterHovered: Bool,
        in context: inout GraphicsContext
    ) {
        let ringLimit = Double(layout.ringCount)
        let fullCircle = SunburstLayout.fullCircle

        // Zooming in: the folder that was clicked grows from its wedge into the center circle.
        if case .zoomIn = frame.kind {
            let depth = frame.depthOffset - 1
            let start = frame.angle(0)
            let end = frame.angle(fullCircle)
            if depth > -1, end - start > 0.0006 {
                let path = sector(
                    center: geometry.center,
                    inner: geometry.radius(atDepth: depth),
                    outer: geometry.radius(atDepth: depth + 1),
                    start: start, end: min(end, start + fullCircle - 1e-6)
                )
                let color = SunburstPalette.color(midAngle: (start + end) / 2, depth: depth, isDirectory: true)
                context.fill(path, with: .color(color))
            }
        }

        for ring in layout.rings {
            for segment in ring {
                let start = frame.angle(segment.startAngle)
                let end = frame.angle(segment.endAngle)
                guard end - start > 0.0006 else { continue }

                let depth = Double(segment.depth) + frame.depthOffset
                guard depth > -1, depth < ringLimit else { continue }
                let inner = geometry.radius(atDepth: depth)
                let outer = geometry.radius(atDepth: depth + 1)
                guard outer - inner > 0.5 else { continue }

                let isHighlighted = highlight?.contains(segment) ?? false
                let color: Color
                if let node = segment.node {
                    color = SunburstPalette.color(
                        midAngle: (start + end) / 2, depth: depth,
                        isDirectory: node.isDirectory, isHighlighted: isHighlighted
                    )
                } else {
                    color = SunburstPalette.color(for: segment, isHighlighted: isHighlighted)
                }

                // Rings sliding in from beyond the edge fade in.
                let edgeFade = min(max(ringLimit - depth, 0), 1)
                context.opacity = frame.opacity * edgeFade

                let path = sector(center: geometry.center, inner: inner, outer: outer, start: start, end: end)
                context.fill(path, with: .color(color))
                if end - start < fullCircle - 1e-6 {
                    context.stroke(path, with: .color(Theme.chartSeparator), lineWidth: 1)
                }
            }
        }
        context.opacity = 1

        // The center circle sits on top, hiding anything that slides into it while zooming out.
        let radius = geometry.holeRadius
        let center = geometry.center
        let hole = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(hole, with: .radialGradient(
            Gradient(colors: [Color(white: isCenterHovered ? 0.25 : 0.21), Color(white: 0.12)]),
            center: center, startRadius: 0, endRadius: radius
        ))
        context.stroke(
            hole,
            with: .color(Color.white.opacity(isCenterHovered ? 0.32 : 0.10)),
            lineWidth: isCenterHovered ? 2 : 1
        )
    }

    /// An annular wedge. Angles are clockwise from 12 o'clock.
    static func sector(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        var path = Path()
        let startAngle = Angle.radians(start - Double.pi / 2)
        let endAngle = Angle.radians(end - Double.pi / 2)
        // A positive delta sweeps clockwise on screen (SwiftUI's y axis points down).
        path.addRelativeArc(center: center, radius: outer, startAngle: startAngle, delta: .radians(end - start))
        if inner > 0.5 {
            path.addRelativeArc(center: center, radius: inner, startAngle: endAngle, delta: .radians(start - end))
        } else {
            path.addLine(to: center)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Center label

struct ChartCenterLabel: View {
    struct Content {
        let title: String
        let size: Int64
        let detail: String
        let hint: String?

        init(title: String, size: Int64, detail: String, hint: String?) {
            self.title = title
            self.size = size
            self.detail = detail
            self.hint = hint
        }

        init(node: FileNode, hint: String?) {
            title = node.name
            size = node.size
            if node.isDirectory {
                detail = node.isUnreadable ? "Couldn't be read" : "\(node.descendantCount.formatted()) items"
            } else {
                detail = node.kind == .symlink ? "Alias" : "File"
            }
            self.hint = hint
        }
    }

    let content: Content
    let holeRadius: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            if let hint = content.hint {
                Label(hint, systemImage: "arrow.up.backward")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }
            Text(content.title)
                .font(.system(size: min(max(holeRadius * 0.12, 11), 16), weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(content.size.byteString)
                .font(.system(size: min(max(holeRadius * 0.2, 15), 28), weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if !content.detail.isEmpty {
                Text(content.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Theme.primaryText)
    }
}

/// What follows the pointer while dragging an item.
struct DragPreview: View {
    let node: FileNode
    let browser: BrowserModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcons.icon(for: node, path: browser.path(for: node)))
                .resizable()
                .frame(width: 20, height: 20)
            Text(node.name)
                .lineLimit(1)
            Text(node.size.byteString)
                .foregroundStyle(Theme.secondaryText)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.2)))
    }
}

/// Actions for an item, shared by the chart's and the list's context menus.
struct ItemMenuItems: View {
    let node: FileNode
    let browser: BrowserModel

    var body: some View {
        if node.isDirectory && !node.children.isEmpty {
            Button("Open") { browser.open(node) }
        }
        Button("Reveal in Finder") { browser.revealInFinder(node) }
        Button("Quick Look") { browser.quickLook(node) }
        Button("Copy Path") { browser.copyPath(node) }
        Divider()
        if browser.isCollected(node) {
            Button("Remove from Collector") { browser.uncollect(node) }
        } else {
            Button("Add to Collector") { browser.collect([node]) }
        }
    }
}

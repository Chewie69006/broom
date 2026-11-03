//
//  SunburstLayout.swift
//  Broom
//

import CoreGraphics
import Foundation

/// One wedge of the sunburst chart.
struct SunburstSegment {
    /// The item this wedge stands for, or nil for a "smaller items" wedge.
    let node: FileNode?
    /// The folder this wedge sits in.
    let owner: FileNode
    /// Ring index. 0 is the ring right around the center circle.
    let depth: Int
    /// Angles in radians, measured clockwise from 12 o'clock.
    let startAngle: Double
    let endAngle: Double
    /// For "smaller items" wedges: how many items and bytes they stand for.
    let hiddenCount: Int
    let hiddenSize: Int64

    var isSmallerItems: Bool { node == nil }
    var size: Int64 { node?.size ?? hiddenSize }
    var midAngle: Double { (startAngle + endAngle) / 2 }

    func contains(angle: Double) -> Bool {
        angle >= startAngle && angle < endAngle
    }
}

/// The wedges to draw for one folder, a few levels deep. Items too thin to see are merged into
/// a grey "smaller items" wedge.
struct SunburstLayout {
    static let ringCount = 6
    static let fullCircle = 2 * Double.pi
    /// Wedges thinner than this (about 0.6°) are merged.
    static let minimumAngle = 0.0105

    let center: FileNode
    let ringCount: Int
    private(set) var rings: [[SunburstSegment]]
    private var positions: [ObjectIdentifier: (ring: Int, index: Int)] = [:]

    init(center: FileNode, ringCount: Int = SunburstLayout.ringCount) {
        self.center = center
        self.ringCount = ringCount
        self.rings = Array(repeating: [], count: ringCount)
        if center.size > 0 {
            addChildren(of: center, depth: 0, start: 0, span: Self.fullCircle)
        }
    }

    var segmentCount: Int { rings.reduce(0) { $0 + $1.count } }

    func segment(ring: Int, index: Int) -> SunburstSegment? {
        guard rings.indices.contains(ring), rings[ring].indices.contains(index) else { return nil }
        return rings[ring][index]
    }

    /// The wedge for `node`, if it's big enough to be drawn.
    func position(of node: FileNode) -> (ring: Int, index: Int)? {
        positions[ObjectIdentifier(node)]
    }

    /// The wedge under `angle` in `ring`. Each ring's wedges are sorted by angle.
    func hitTest(angle: Double, ring: Int) -> Int? {
        guard rings.indices.contains(ring) else { return nil }
        let segments = rings[ring]
        var low = 0
        var high = segments.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].startAngle <= angle {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0, segments[found].contains(angle: angle) else { return nil }
        return found
    }

    private mutating func addChildren(of folder: FileNode, depth: Int, start: Double, span: Double) {
        guard depth < ringCount, folder.size > 0 else { return }
        let scale = span / Double(folder.size)
        let children = folder.children
        var angle = start
        var shownSize: Int64 = 0
        var index = 0

        // Children are sorted biggest first, so once one is too thin, the rest are too.
        while index < children.count {
            let child = children[index]
            let childSpan = Double(child.size) * scale
            if child.size <= 0 || childSpan < Self.minimumAngle { break }
            positions[ObjectIdentifier(child)] = (depth, rings[depth].count)
            rings[depth].append(SunburstSegment(
                node: child, owner: folder, depth: depth,
                startAngle: angle, endAngle: angle + childSpan,
                hiddenCount: 0, hiddenSize: 0
            ))
            if child.isDirectory {
                addChildren(of: child, depth: depth + 1, start: angle, span: childSpan)
            }
            angle += childSpan
            shownSize += child.size
            index += 1
        }

        let hiddenSize = folder.size - shownSize
        let end = start + span
        if hiddenSize > 0, index < children.count, end - angle > 0.0005 {
            rings[depth].append(SunburstSegment(
                node: nil, owner: folder, depth: depth,
                startAngle: angle, endAngle: end,
                hiddenCount: children.count - index, hiddenSize: hiddenSize
            ))
        }
    }

    /// Where `descendant` sits inside `ancestor`'s full circle, as a range of angles, plus how many
    /// levels apart they are. Used to animate zooming in and out.
    static func angularRange(of descendant: FileNode, within ancestor: FileNode) -> (start: Double, end: Double, levels: Int)? {
        var chain: [FileNode] = []
        var node = descendant
        while node !== ancestor {
            chain.append(node)
            guard let parent = node.parent else { return nil }
            node = parent
        }
        var start = 0.0
        var span = 1.0
        var folder = ancestor
        for child in chain.reversed() {
            guard folder.size > 0 else { break }
            var before: Int64 = 0
            for sibling in folder.children {
                if sibling === child { break }
                before += sibling.size
            }
            start += span * Double(before) / Double(folder.size)
            span *= Double(child.size) / Double(folder.size)
            folder = child
        }
        return (start * fullCircle, (start + span) * fullCircle, chain.count)
    }
}

/// Converts between screen points and the chart's rings and angles.
///
/// Rings get slightly thinner toward the outside, like DaisyDisk's. Depths can be fractional
/// (for animation), so the radius is a continuous function of depth.
struct SunburstGeometry {
    static let ringDecay = 0.86

    let center: CGPoint
    let holeRadius: CGFloat
    let outerRadius: CGFloat
    let ringCount: Int
    private let firstRingWidth: Double

    init(size: CGSize, ringCount: Int = SunburstLayout.ringCount) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        let half = min(size.width, size.height) / 2
        outerRadius = max(half - min(8, half * 0.08), 1)
        holeRadius = outerRadius * 0.27
        self.ringCount = ringCount
        let total = Double(outerRadius - holeRadius)
        let q = Self.ringDecay
        firstRingWidth = total * (1 - q) / (1 - pow(q, Double(ringCount)))
    }

    /// Distance from the center to the inner edge of ring `depth`.
    func radius(atDepth depth: Double) -> CGFloat {
        if depth <= 0 {
            return max(holeRadius + CGFloat(firstRingWidth * depth), 0)
        }
        let q = Self.ringDecay
        return holeRadius + CGFloat(firstRingWidth * (1 - pow(q, depth)) / (1 - q))
    }

    /// The (fractional) ring at `radius`, or nil outside the rings.
    func depth(atRadius radius: CGFloat) -> Double? {
        guard radius >= holeRadius, radius < outerRadius else { return nil }
        let q = Self.ringDecay
        let x = 1 - Double(radius - holeRadius) * (1 - q) / firstRingWidth
        guard x > 0 else { return nil }
        return log(x) / log(q)
    }

    /// Angle (clockwise from 12 o'clock, 0..<2π) and distance of `point` from the center.
    func polar(of point: CGPoint) -> (angle: Double, radius: CGFloat) {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        var angle = atan2(dy, dx) + Double.pi / 2
        if angle < 0 { angle += SunburstLayout.fullCircle }
        if angle >= SunburstLayout.fullCircle { angle -= SunburstLayout.fullCircle }
        return (angle, CGFloat((dx * dx + dy * dy).squareRoot()))
    }
}

/// How the chart animates from one folder to another.
struct SunburstTransition {
    enum Kind {
        /// First appearance: wedges sweep around clockwise.
        case reveal
        /// The new folder was the wedge at `start...end`, `levels` rings out. It grows to fill the
        /// chart.
        case zoomIn(start: Double, end: Double, levels: Int)
        /// The old folder becomes the wedge at `start...end` of the new one.
        case zoomOut(start: Double, end: Double, levels: Int)
        /// Unrelated folders: just fade in.
        case fade
    }

    let id: Int
    let kind: Kind
    let startDate: Date
    let duration: TimeInterval

    /// Eased progress from 0 to 1.
    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 1 }
        let t = min(max(date.timeIntervalSince(startDate) / duration, 0), 1)
        // Ease out cubic: fast start, gentle landing.
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }

    /// What to apply to the final layout at progress `t`.
    func frame(at t: Double) -> Frame {
        switch kind {
        case .reveal:
            return Frame(kind: kind, t: t, depthOffset: 0, opacity: min(1, t * 1.6))
        case .zoomIn(_, _, let levels):
            return Frame(kind: kind, t: t, depthOffset: Double(levels) * (1 - t), opacity: 1)
        case .zoomOut(_, _, let levels):
            return Frame(kind: kind, t: t, depthOffset: -Double(levels) * (1 - t), opacity: 1)
        case .fade:
            return Frame(kind: kind, t: t, depthOffset: 0, opacity: t)
        }
    }

    struct Frame {
        let kind: Kind
        let t: Double
        let depthOffset: Double
        let opacity: Double

        static let identity = Frame(kind: .fade, t: 1, depthOffset: 0, opacity: 1)

        /// Where a layout angle is drawn during the animation.
        func angle(_ angle: Double) -> Double {
            let full = SunburstLayout.fullCircle
            switch kind {
            case .reveal:
                return angle * t
            case .zoomIn(let start, let end, _):
                let squeezed = start + angle * (end - start) / full
                return squeezed + (angle - squeezed) * t
            case .zoomOut(let start, let end, _):
                let span = max(end - start, 1e-9)
                let stretched = (angle - start) * full / span
                return min(max(stretched + (angle - stretched) * t, 0), full)
            case .fade:
                return angle
            }
        }
    }
}

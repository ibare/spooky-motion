// 시간에 따른 음량 그래프. 누르거나 끌면 그 시각을 onSeek 로 알린다.
//
// 가로: 파일 처음부터 끝까지. 세로: LUFS.
// 단기(3초) 음량은 글자색 진한 선, 순간(0.4초) 음량은 옅은 회색 선(화면 한 칸에 든 값 중 가장 큰 값)으로 그린다.
// 목표 ±허용 범위는 초록 띠, 문제 구간은 세로 색 띠, FCP 플레이헤드는 노란 선이다.

import Cocoa

final class LoudnessGraphView: NSView {
    // MARK: 설정 (대략값)

    static let topLUFS = 0.0
    static let bottomLUFS = -50.0
    static let gridStep = 10.0
    private static let leftInset: CGFloat = 30
    private static let verticalInset: CGFloat = 6

    // MARK: 입력

    var result: LoudnessResult? { didSet { needsDisplay = true } }
    var problems: [LoudnessProblem] = [] { didSet { needsDisplay = true } }
    var target: LoudnessTarget = .lecture { didSet { needsDisplay = true } }
    /// 파일 기준 시각(초). nil 이면 그리지 않는다.
    var playhead: Double? { didSet { if playhead != oldValue { needsDisplay = true } } }
    /// 파일 기준 시각을 FCP 타임코드로 바꾼다 (마우스를 올렸을 때 보여 준다)
    var describeTime: ((Double) -> String)?
    var onSeek: ((Double) -> Void)?

    private var hoverPoint: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 170) }

    /// 단기 음량 선. 강조색(보통 파랑)은 '작음' 표시와 헷갈려서 글자색을 쓴다.
    static let shortTermColor = NSColor.labelColor

    static func color(for kind: LoudnessProblem.Kind) -> NSColor {
        switch kind {
        case .spike: return .systemRed
        case .peak: return .systemPurple
        case .quiet: return .systemBlue
        }
    }

    private var plotRect: NSRect {
        NSRect(x: Self.leftInset, y: Self.verticalInset,
               width: max(1, bounds.width - Self.leftInset - 4),
               height: max(1, bounds.height - Self.verticalInset * 2))
    }

    private func y(_ lufs: Double) -> CGFloat {
        let plot = plotRect
        let clamped = min(Self.topLUFS, max(Self.bottomLUFS, lufs))
        let t = (Self.topLUFS - clamped) / (Self.topLUFS - Self.bottomLUFS)
        return plot.minY + CGFloat(t) * plot.height
    }

    private func x(_ seconds: Double, duration: Double) -> CGFloat {
        let plot = plotRect
        return plot.minX + CGFloat(seconds / max(duration, 0.001)) * plot.width
    }

    private func seconds(atX px: CGFloat, duration: Double) -> Double {
        let plot = plotRect
        return min(duration, max(0, Double((px - plot.minX) / plot.width) * duration))
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let plot = plotRect

        drawGrid(plot)
        guard let result, result.duration > 0 else { return }
        let duration = result.duration

        // 목표 ±허용 범위
        let band = NSRect(x: plot.minX, y: y(target.integrated + LoudnessSettings.tolerance),
                          width: plot.width,
                          height: y(target.integrated - LoudnessSettings.tolerance) - y(target.integrated + LoudnessSettings.tolerance))
        NSColor.systemGreen.withAlphaComponent(0.14).setFill()
        band.fill()
        let targetLine = NSBezierPath()
        targetLine.move(to: NSPoint(x: plot.minX, y: y(target.integrated)))
        targetLine.line(to: NSPoint(x: plot.maxX, y: y(target.integrated)))
        targetLine.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.systemGreen.withAlphaComponent(0.7).setStroke()
        targetLine.stroke()

        // 문제 구간
        for problem in problems {
            let x0 = x(problem.start, duration: duration)
            let x1 = max(x0 + 2, x(problem.end, duration: duration))
            Self.color(for: problem.kind).withAlphaComponent(0.28).setFill()
            NSRect(x: x0, y: plot.minY, width: x1 - x0, height: plot.height).fill()
        }

        // 순간(옅게, 칸마다 최대) 과 단기(진하게, 칸 가운데 값)
        let count = result.momentary.count
        if count > 0 {
            let columns = Int(plot.width)
            let momentaryPath = NSBezierPath()
            let shortPath = NSBezierPath()
            var momentaryOpen = false
            var shortOpen = false
            for column in 0..<columns {
                let i0 = column * count / columns
                let i1 = max(i0 + 1, (column + 1) * count / columns)
                let px = plot.minX + CGFloat(column) + 0.5
                let m = result.momentary[i0..<min(i1, count)].max() ?? -.infinity
                if m.isFinite {
                    let point = NSPoint(x: px, y: y(m))
                    if momentaryOpen { momentaryPath.line(to: point) } else { momentaryPath.move(to: point) }
                    momentaryOpen = true
                } else {
                    momentaryOpen = false
                }
                let s = result.shortTerm[min(count - 1, (i0 + i1) / 2)]
                if s.isFinite {
                    let point = NSPoint(x: px, y: y(s))
                    if shortOpen { shortPath.line(to: point) } else { shortPath.move(to: point) }
                    shortOpen = true
                } else {
                    shortOpen = false
                }
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
            momentaryPath.lineWidth = 1
            momentaryPath.stroke()
            Self.shortTermColor.setStroke()
            shortPath.lineWidth = 1.6
            shortPath.lineJoinStyle = .round
            shortPath.stroke()
        }

        // FCP 플레이헤드
        if let playhead, playhead >= 0, playhead <= duration {
            let px = x(playhead, duration: duration)
            NSColor.systemYellow.setFill()
            NSRect(x: px - 0.75, y: plot.minY, width: 1.5, height: plot.height).fill()
        }

        drawLegend(plot)
        drawHover(plot, result: result)
    }

    private func drawGrid(_ plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        var level = Self.topLUFS - Self.gridStep
        while level > Self.bottomLUFS {
            let py = y(level)
            NSColor.separatorColor.setFill()
            NSRect(x: plot.minX, y: py, width: plot.width, height: 0.5).fill()
            let label = "\(Int(level))" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: plot.minX - size.width - 4, y: py - size.height / 2), withAttributes: attributes)
            level -= Self.gridStep
        }
    }

    private func drawLegend(_ plot: NSRect) {
        let font = NSFont.systemFont(ofSize: 9)
        let items: [(String, NSColor)] = [
            ("단기 3초", Self.shortTermColor), ("순간 0.4초", .secondaryLabelColor),
            ("튐", Self.color(for: .spike)), ("피크", Self.color(for: .peak)), ("작음", Self.color(for: .quiet)),
        ]
        let text = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "   ")) }
            text.append(NSAttributedString(string: "■ ", attributes: [.font: font, .foregroundColor: item.1]))
            text.append(NSAttributedString(string: item.0, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let size = text.size()
        text.draw(at: NSPoint(x: plot.maxX - size.width - 4, y: plot.minY + 2))
    }

    private func drawHover(_ plot: NSRect, result: LoudnessResult) {
        guard let hoverPoint, plot.contains(hoverPoint) else { return }
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: hoverPoint.x - 0.5, y: plot.minY, width: 1, height: plot.height).fill()

        let time = seconds(atX: hoverPoint.x, duration: result.duration)
        let index = min(result.momentary.count - 1, max(0, Int(time / LoudnessResult.step)))
        func text(_ v: Double) -> String { v.isFinite ? String(format: "%.1f", v) : "–" }
        let label = "\(describeTime?(time) ?? String(format: "%.1f초", time))  순간 \(text(result.momentary[index]))  단기 \(text(result.shortTerm[index]))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = label.size(withAttributes: attributes)
        var origin = NSPoint(x: hoverPoint.x + 6, y: plot.maxY - size.height - 6)
        if origin.x + size.width + 6 > plot.maxX { origin.x = hoverPoint.x - size.width - 10 }
        let box = NSRect(x: origin.x - 3, y: origin.y - 2, width: size.width + 6, height: size.height + 4)
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        label.draw(at: origin, withAttributes: attributes)
    }

    // MARK: 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }

    private func seek(_ event: NSEvent) {
        guard let result else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        let time = seconds(atX: point.x, duration: result.duration)
        playhead = time
        onSeek?(time)
    }
}

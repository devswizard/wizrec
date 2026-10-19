import AppKit
import TimelineEngine
import TSCProjKit

extension TimelineCanvas {
    func addTrackButtonRect(_ L: TimelineLayout) -> CGRect {
        let c = L.cornerRect
        return CGRect(x: c.maxX - 26, y: c.minY + (c.height - 20) / 2, width: 20, height: 20)
    }

    func drawAll(_ ctx: CGContext, layout L: TimelineLayout, dirty: CGRect) {
        Palette.background.setFill()
        ctx.fill(dirty)

        // Clip area: rows, clips, transitions, previews.
        ctx.saveGState()
        ctx.clip(to: L.clipArea)
        drawRows(ctx, L, dirty)
        drawMarkerLines(ctx, L)
        drawClips(ctx, L, dirty)
        drawPreviews(ctx, L)
        ctx.restoreGState()

        drawRuler(ctx, L, dirty)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: L.metrics.rulerHeight, width: L.metrics.headerWidth,
                            height: max(0, bounds.height - L.metrics.rulerHeight)))
        drawHeaders(ctx, L, dirty)
        ctx.restoreGState()
        drawCorner(ctx, L)
        drawPlayhead(ctx, L)
    }

    // MARK: Rows

    func drawRows(_ ctx: CGContext, _ L: TimelineLayout, _ dirty: CGRect) {
        for (i, row) in L.rows.enumerated() {
            let r = L.rowRect(row)
            guard r.intersects(dirty) else { continue }
            let locked = snapshot.track(row.trackIndex)?.locked ?? false
            (locked ? Palette.rowLocked : (i % 2 == 0 ? Palette.rowEven : Palette.rowOdd)).setFill()
            ctx.fill(r)
            if locked { drawHatch(ctx, in: r, color: Palette.separator.withAlphaComponent(0.5)) }
            if let drop = dropTarget, drop.track == row.trackIndex {
                Palette.marqueeFill.setFill(); ctx.fill(r)
            }
        }
    }

    func drawHatch(_ ctx: CGContext, in r: CGRect, color: NSColor) {
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        var x = (r.minX / 10).rounded(.down) * 10 - r.height
        while x < r.maxX {
            ctx.move(to: CGPoint(x: x, y: r.maxY)); ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 10
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Clips

    /// Clips being dragged are drawn dimmed in place; their preview is drawn by `drawPreviews`.
    var draggedIDs: Set<Int64> {
        switch drag {
        case .move(_, let plan): Set(plan.ids)
        default: []
        }
    }

    func drawClips(_ ctx: CGContext, _ L: TimelineLayout, _ dirty: CGRect) {
        let visible = L.clipArea.intersection(dirty)
        let dragged = draggedIDs
        let moved = previewPositions
        let invalidRipple: Bool = if case .rippleMove(_, let plan) = drag { !plan.isValid } else { false }
        for track in snapshot.tracks {
            for c in track.clips {
                var item = c, ti = track.index
                if let pos = moved[c.id] { item.start = pos.start; item.duration = max(1, pos.duration); ti = pos.track }
                guard let r = L.clipRect(track: ti, start: item.start, duration: item.duration),
                      r.intersects(visible) else { continue }
                ctx.saveGState()
                if track.videoHidden || dragged.contains(c.id) { ctx.setAlpha(dragged.contains(c.id) ? 0.35 : 0.5) }
                drawClip(ctx, item, rect: r, layout: L, visible: visible, selected: model.selection.contains(c.id),
                         muted: track.audioMuted)
                if invalidRipple, moved[c.id] != nil, model.selection.contains(c.id) {
                    ctx.setStrokeColor(Palette.invalid.cgColor); ctx.setLineWidth(2)
                    ctx.stroke(r.insetBy(dx: 1, dy: 1))
                }
                ctx.restoreGState()
            }
            guard moved.isEmpty, let row = L.row(forTrack: track.index), L.rowRect(row).intersects(visible) else { continue }
            for tr in track.transitions {
                guard let r = L.clipRect(track: track.index, start: tr.start, duration: tr.end - tr.start),
                      r.intersects(visible) else { continue }
                drawTransition(ctx, tr, rect: r)
            }
        }
    }

    func drawClip(_ ctx: CGContext, _ c: TimelineClipItem, rect r: CGRect, layout L: TimelineLayout, visible: CGRect,
                  selected: Bool, muted: Bool) {
        let base = Palette.clip(c.style)
        let body = r.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(5, body.width / 2, body.height / 2)
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let colors = clipColors(c.style)
        ctx.setFillColor(colors.body)
        ctx.fill(body)
        guard body.width >= 3 else { ctx.restoreGState(); return }

        let strip: CGFloat = body.height >= 34 ? 16 : 0
        let content = CGRect(x: body.minX, y: body.minY + strip, width: body.width, height: body.height - strip)
        let vis = content.intersection(visible)
        if !vis.isNull, vis.width > 0 {
            switch c.style {
            case .group: drawLanes(ctx, c, in: content, layout: L)
            case .callout: drawCalloutBody(c, in: content, base: base)
            case .shader: drawShaderBody(ctx, in: content)
            case .audio: drawWaveform(ctx, c.audioSpans, in: content, visible: vis, layout: L, muted: muted)
            default:
                if !c.videoSpans.isEmpty && !c.audioSpans.isEmpty && content.height >= 30 {
                    let audioH = (content.height * 0.36).rounded()
                    let v = CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height - audioH)
                    let a = CGRect(x: content.minX, y: v.maxY, width: content.width, height: audioH)
                    drawFilmstrip(ctx, c.videoSpans, in: v, visible: v.intersection(visible), layout: L)
                    drawWaveform(ctx, c.audioSpans, in: a, visible: a.intersection(visible), layout: L, muted: muted)
                } else if !c.videoSpans.isEmpty {
                    drawFilmstrip(ctx, c.videoSpans, in: content, visible: vis, layout: L)
                } else if !c.audioSpans.isEmpty {
                    drawWaveform(ctx, c.audioSpans, in: content, visible: vis, layout: L, muted: muted)
                }
            }
        }
        // Stitched cuts.
        if !c.cuts.isEmpty {
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            for cut in c.cuts {
                let x = L.x(ofTicks: cut).rounded() + 0.5
                ctx.move(to: CGPoint(x: x, y: body.minY)); ctx.addLine(to: CGPoint(x: x, y: body.maxY))
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // Name strip.
        if strip > 0 {
            let s = CGRect(x: body.minX, y: body.minY, width: body.width, height: strip)
            base.setFill(); ctx.fill(s)
            drawClipLabel(c, strip: s, visible: visible)
        }
        ctx.restoreGState()

        // Outline.
        ctx.addPath(path)
        if selected {
            ctx.setStrokeColor(Palette.selection.cgColor); ctx.setLineWidth(2)
        } else {
            ctx.setStrokeColor(colors.outline); ctx.setLineWidth(1)
        }
        ctx.strokePath()
    }

    func drawClipLabel(_ c: TimelineClipItem, strip s: CGRect, visible: CGRect) {
        var badges: [String] = []
        if abs(c.speed - 1) > 0.001 { badges.append(String(format: "%.2f×", c.speed)) }
        if c.effectCount > 0 { badges.append("fx\(c.effectCount > 1 ? " \(c.effectCount)" : "")") }
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let small = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let white = NSColor(white: 1, alpha: 0.95)
        var right = s.maxX - 5
        if !badges.isEmpty, s.width > 90 {
            let text = NSAttributedString(string: badges.joined(separator: "  "),
                                          attributes: [.font: small, .foregroundColor: NSColor(white: 1, alpha: 0.8)])
            let w = text.size().width
            text.draw(at: CGPoint(x: right - w, y: s.minY + 2))
            right -= w + 6
        }
        // Sticky label: stays readable when the clip starts left of the visible area.
        let x = max(s.minX, visible.minX) + 6
        let room = right - x
        guard room > 12 else { return }
        let text = NSAttributedString(string: c.name, attributes: [.font: font, .foregroundColor: white])
        text.draw(with: CGRect(x: x, y: s.minY + 1.5, width: room, height: s.height - 2),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    func drawFilmstrip(_ ctx: CGContext, _ spans: [TimelineMediaSpan], in rect: CGRect, visible: CGRect,
                       layout L: TimelineLayout) {
        guard !visible.isNull, visible.width > 0, rect.height > 6, let first = spans.first else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        let scale = window?.backingScaleFactor ?? 2
        var aspect: CGFloat = 16 / 9
        if let any = art.anyThumbnail(of: first.media), any.height > 0 {
            aspect = min(max(CGFloat(any.width) / CGFloat(any.height), 0.3), 4)
        }
        let tileH = rect.height
        let tileW = max(20, (tileH * aspect).rounded())
        let pixel = Int(((max(tileW, tileH) * scale) / 32).rounded(.up) * 32)
        let x0 = L.x(ofTicks: 0)
        var k = ((visible.minX - x0) / tileW).rounded(.down)
        while x0 + k * tileW < visible.maxX {
            let tile = CGRect(x: x0 + k * tileW, y: rect.minY, width: tileW, height: tileH)
            k += 1
            let center = L.ticks(atX: tile.midX)
            guard let span = spans.first(where: { center >= $0.start && center < $0.end })
                    ?? spans.min(by: { abs($0.start - center) < abs($1.start - center) }) else { continue }
            let t = min(max(center, span.start), span.end - 1)
            let secs = max(0, span.mediaSeconds(at: t, editRate: snapshot.editRate))
            if let img = art.thumbnail(span.media, seconds: (secs * 10).rounded() / 10, size: pixel) {
                drawImage(ctx, img, aspectFill: tile)
            } else {
                NSColor(white: 1, alpha: 0.05).setFill(); ctx.fill(tile.insetBy(dx: 0.5, dy: 0))
            }
            NSColor(white: 0, alpha: 0.25).setFill()
            ctx.fill(CGRect(x: tile.maxX - 0.5, y: tile.minY, width: 0.5, height: tile.height))
        }
        ctx.restoreGState()
    }

    func drawImage(_ ctx: CGContext, _ img: CGImage, aspectFill r: CGRect) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        let s = max(r.width / iw, r.height / ih)
        let w = iw * s, h = ih * s
        let dst = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: 0, y: dst.minY + dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: dst)
        ctx.restoreGState()
    }

    func drawWaveform(_ ctx: CGContext, _ spans: [TimelineMediaSpan], in rect: CGRect, visible: CGRect,
                      layout L: TimelineLayout, muted: Bool) {
        guard !visible.isNull, visible.width > 0, rect.height > 4 else { return }
        NSColor(white: 0, alpha: 0.12).setFill()
        ctx.fill(rect)
        let mid = rect.midY, half = rect.height / 2 - 1
        let color = muted ? NSColor(white: 1, alpha: 0.35) : Palette.waveform
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        var drewAny = false
        for span in spans {
            guard let wf = art.waveform(span.media) else { continue }
            let sx = max(visible.minX, L.x(ofTicks: span.start)), ex = min(visible.maxX, L.x(ofTicks: span.end))
            guard ex > sx else { continue }
            var x = sx.rounded(.down) + 0.5
            while x < ex {
                let a = span.mediaSeconds(at: L.ticks(atX: x - 0.5), editRate: snapshot.editRate)
                let b = span.mediaSeconds(at: L.ticks(atX: x + 0.5), editRate: snapshot.editRate)
                if let (mn, mx) = wf.range(from: a, to: b) {
                    let top = mid - CGFloat(min(1, mx)) * half, bottom = mid - CGFloat(max(-1, mn)) * half
                    ctx.move(to: CGPoint(x: x, y: min(top, mid - 0.5)))
                    ctx.addLine(to: CGPoint(x: x, y: max(bottom, mid + 0.5)))
                    drewAny = true
                }
                x += 1
            }
        }
        if drewAny { ctx.strokePath() } else {
            ctx.move(to: CGPoint(x: visible.minX, y: mid)); ctx.addLine(to: CGPoint(x: visible.maxX, y: mid))
            ctx.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            ctx.strokePath()
        }
    }

    func drawLanes(_ ctx: CGContext, _ c: TimelineClipItem, in rect: CGRect, layout L: TimelineLayout) {
        let lanes = Array(c.lanes.prefix(6))
        guard !lanes.isEmpty, rect.height > 6 else { return }
        let gap: CGFloat = 2
        let h = max(2, (rect.height - 4 - gap * CGFloat(lanes.count - 1)) / CGFloat(lanes.count))
        for (i, lane) in lanes.enumerated() {
            // Inner track 0 at the bottom, as on the main timeline.
            let y = rect.maxY - 2 - CGFloat(i + 1) * h - CGFloat(i) * gap
            for s in lane {
                let x0 = L.x(ofTicks: s.start), x1 = L.x(ofTicks: s.end)
                let r = CGRect(x: x0 + 0.5, y: y, width: max(1, x1 - x0 - 1), height: h)
                Palette.clip(s.style).withAlphaComponent(0.85).setFill()
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(2, r.width / 2), cornerHeight: min(2, h / 2), transform: nil))
                ctx.fillPath()
            }
        }
    }

    func drawCalloutBody(_ c: TimelineClipItem, in rect: CGRect, base: NSColor) {
        guard rect.height > 12, rect.width > 20 else { return }
        let text = NSAttributedString(string: "T  " + c.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ])
        text.draw(with: rect.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    func drawShaderBody(_ ctx: CGContext, in rect: CGRect) {
        let colors = [NSColor(hex: 0x4F46E5).cgColor, NSColor(hex: 0x0EA5E9).cgColor, NSColor(hex: 0xA855F7).cgColor]
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                 locations: [0, 0.5, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setAlpha(0.55)
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY),
                               options: [])
        ctx.restoreGState()
    }

    func drawTransition(_ ctx: CGContext, _ tr: TimelineTransitionItem, rect r: CGRect) {
        let box = r.insetBy(dx: 0, dy: 3)
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
        ctx.fillPath()
        // Bow-tie mark: two triangles meeting in the middle.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)
        ctx.move(to: CGPoint(x: box.minX, y: box.minY)); ctx.addLine(to: CGPoint(x: box.midX, y: box.midY))
        ctx.addLine(to: CGPoint(x: box.minX, y: box.maxY)); ctx.closePath()
        ctx.move(to: CGPoint(x: box.maxX, y: box.minY)); ctx.addLine(to: CGPoint(x: box.midX, y: box.midY))
        ctx.addLine(to: CGPoint(x: box.maxX, y: box.maxY)); ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        if box.width > 60 {
            let text = NSAttributedString(string: tr.name, attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            text.draw(with: CGRect(x: box.minX + 4, y: box.maxY - 14, width: box.width - 8, height: 12),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }

    // MARK: Previews (drag ghosts, marquee, snap guide, drop indicator)

    func drawPreviews(_ ctx: CGContext, _ L: TimelineLayout) {
        var guide: Int64?
        switch drag {
        case .move(_, let plan):
            guide = plan.guide
            for id in plan.ids {
                guard let (track, c) = snapshot.clip(id),
                      let r = L.clipRect(track: track + plan.trackOffset, start: c.start + plan.delta, duration: c.duration)
                else { continue }
                drawClip(ctx, c, rect: r, layout: L, visible: L.clipArea, selected: true, muted: false)
                if !plan.isValid {
                    ctx.setStrokeColor(Palette.invalid.cgColor); ctx.setLineWidth(2)
                    ctx.stroke(r.insetBy(dx: 1, dy: 1))
                }
            }
        case .trim(_, let plan):
            guide = plan.guide  // the resized clip is drawn by drawClips from previewPositions
        case .rippleMove(_, let plan):
            guide = plan.guide
            if let row = L.row(forTrack: plan.toTrack) {
                let rr = L.rowRect(row), x = L.x(ofTicks: plan.start).rounded()
                (plan.isValid ? Palette.marqueeStroke : Palette.invalid).setFill()
                ctx.fill(CGRect(x: x - 1, y: rr.minY, width: 2, height: rr.height))
            }
        case .marquee(let oc, let pc, _):
            let o = viewPoint(oc), p = viewPoint(pc)
            let r = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y))
            Palette.marqueeFill.setFill(); ctx.fill(r)
            ctx.setStrokeColor(Palette.marqueeStroke.cgColor); ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        default: break
        }
        if let drop = dropTarget, let row = L.row(forTrack: drop.track) {
            let rr = L.rowRect(row)
            let x = L.x(ofTicks: drop.ticks).rounded()
            Palette.marqueeStroke.setFill()
            ctx.fill(CGRect(x: x - 1, y: rr.minY, width: 2, height: rr.height))
        }
        if let g = guide {
            let x = L.x(ofTicks: g).rounded() + 0.5
            ctx.setStrokeColor(Palette.snapGuide.cgColor); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: L.clipArea.minY)); ctx.addLine(to: CGPoint(x: x, y: L.clipArea.maxY))
            ctx.strokePath()
        }
    }

    // MARK: Ruler

    func drawRuler(_ ctx: CGContext, _ L: TimelineLayout, _ dirty: CGRect) {
        let r = L.rulerRect
        guard r.intersects(dirty) else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        Palette.ruler.setFill(); ctx.fill(r)
        Palette.separator.setFill(); ctx.fill(CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1))
        let fps = snapshot.frameRate.double > 0 ? snapshot.frameRate.double : 30
        let scale = RulerScale.choose(pointsPerSecond: L.pointsPerSecond, fps: fps)
        let rate = Double(snapshot.editRate)
        let visibleStart = max(0, Double(L.ticks(atX: max(r.minX, dirty.minX) - 60)) / rate)
        let visibleEnd = Double(L.ticks(atX: min(r.maxX, dirty.maxX) + 1)) / rate
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.secondaryText]
        ctx.setFillColor(Palette.tick.cgColor)
        var i = (visibleStart / scale.major).rounded(.down)
        while i * scale.major <= visibleEnd {
            let secs = i * scale.major
            let ticks = Int64((secs * rate).rounded())
            let x = L.x(ofTicks: ticks).rounded()
            ctx.fill(CGRect(x: x, y: r.maxY - 12, width: 1, height: 11))
            let label = TimelineTimecode.label(ticks, editRate: snapshot.editRate, fps: snapshot.frameRate,
                                               frames: scale.showsFrames)
            NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: x + 3, y: r.minY + 3))
            if scale.minorCount > 1 {
                for m in 1..<scale.minorCount {
                    let mt = Int64(((secs + scale.major * Double(m) / Double(scale.minorCount)) * rate).rounded())
                    let mx = L.x(ofTicks: mt).rounded()
                    ctx.fill(CGRect(x: mx, y: r.maxY - 5, width: 1, height: 4))
                }
            }
            i += 1
        }
        drawMarkers(ctx, L, ruler: r)
        ctx.restoreGState()
    }

    func drawMarkers(_ ctx: CGContext, _ L: TimelineLayout, ruler r: CGRect) {
        let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        for m in snapshot.markers {
            let x = L.x(ofTicks: m.time).rounded()
            guard x > r.minX - 80, x < r.maxX + 8 else { continue }
            let pin = CGMutablePath()
            pin.move(to: CGPoint(x: x - 5, y: r.maxY - 11))
            pin.addLine(to: CGPoint(x: x + 5, y: r.maxY - 11))
            pin.addLine(to: CGPoint(x: x + 5, y: r.maxY - 5))
            pin.addLine(to: CGPoint(x: x, y: r.maxY - 1))
            pin.addLine(to: CGPoint(x: x - 5, y: r.maxY - 5))
            pin.closeSubpath()
            ctx.addPath(pin)
            ctx.setFillColor(Palette.marker.cgColor)
            ctx.fillPath()
            if !m.name.isEmpty {
                NSAttributedString(string: m.name, attributes: [.font: font, .foregroundColor: Palette.marker])
                    .draw(at: CGPoint(x: x + 7, y: r.maxY - 14))
            }
        }
    }

    func drawMarkerLines(_ ctx: CGContext, _ L: TimelineLayout) {
        guard !snapshot.markers.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(Palette.marker.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [2, 3])
        for m in snapshot.markers {
            let x = L.x(ofTicks: m.time).rounded() + 0.5
            guard x >= L.clipArea.minX, x <= L.clipArea.maxX else { continue }
            ctx.move(to: CGPoint(x: x, y: L.clipArea.minY)); ctx.addLine(to: CGPoint(x: x, y: L.clipArea.maxY))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Headers

    func drawHeaders(_ ctx: CGContext, _ L: TimelineLayout, _ dirty: CGRect) {
        for row in L.rows {
            let h = L.headerRect(row)
            guard h.intersects(dirty), let t = snapshot.track(row.trackIndex) else { continue }
            let hasSelection = t.clips.contains { model.selection.contains($0.id) }
            (hasSelection ? Palette.headerSelected : Palette.header).setFill()
            ctx.fill(h)
            Palette.separator.setFill()
            ctx.fill(CGRect(x: h.maxX - 1, y: h.minY, width: 1, height: h.height))
            ctx.fill(CGRect(x: h.minX, y: h.maxY, width: h.width, height: L.metrics.rowGap))
            let name = NSAttributedString(string: t.name, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: Palette.text,
            ])
            let firstButton = L.buttonRect(TrackHeaderControl.allCases[0], in: row).minX
            let nameY = h.minY + min(9, max(2, (h.height - 16) / 2))
            name.draw(with: CGRect(x: h.minX + 10, y: nameY, width: max(0, firstButton - h.minX - 14), height: 16),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            if h.height >= 44 {
                let count = NSAttributedString(string: "\(t.clips.count) clip\(t.clips.count == 1 ? "" : "s")",
                                               attributes: [.font: NSFont.systemFont(ofSize: 9.5),
                                                            .foregroundColor: Palette.secondaryText])
                count.draw(at: CGPoint(x: h.minX + 10, y: nameY + 17))
            }
            for control in TrackHeaderControl.allCases {
                drawHeaderButton(control, track: t, rect: L.buttonRect(control, in: row))
            }
        }
    }

    func drawHeaderButton(_ control: TrackHeaderControl, track t: TimelineTrackItem, rect: CGRect) {
        let (on, symbol, onSymbol, warn): (Bool, String, String, Bool) = switch control {
        case .audioMuted: (t.audioMuted, "speaker.wave.2.fill", "speaker.slash.fill", true)
        case .videoHidden: (t.videoHidden, "eye.fill", "eye.slash.fill", true)
        case .locked: (t.locked, "lock.open.fill", "lock.fill", true)
        case .magnetic: (t.magnetic, "rectangle.compress.vertical", "rectangle.compress.vertical", false)
        }
        if on {
            (warn ? Palette.buttonWarn : Palette.buttonOn).withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        let color = on ? (warn ? Palette.buttonWarn : Palette.buttonOn) : Palette.buttonOff
        drawSymbol(on ? onSymbol : symbol, in: rect.insetBy(dx: 3, dy: 3), color: color)
    }

    var isDark: Bool { NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Body fill and outline of a clip style for the current appearance.
    func clipColors(_ style: TimelineClipStyle) -> (body: CGColor, outline: CGColor) {
        let key = "\(style.rawValue)|\(isDark)"
        if let c = clipColorCache[key] { return c }
        let base = Palette.clip(style)
        let bg = Palette.background.usingColorSpace(.sRGB) ?? Palette.background
        let c = (body: (base.blended(withFraction: 0.45, of: bg) ?? base).cgColor,
                 outline: (base.shadow(withLevel: 0.35) ?? base).cgColor)
        clipColorCache[key] = c
        return c
    }

    /// Draws an SF Symbol fitted in `rect`, tinted `color`; rasterised once per size, colour and appearance.
    func drawSymbol(_ name: String, in rect: CGRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = String(format: "%@|%.0fx%.0f|%.3f,%.3f,%.3f,%.3f", name, rect.width, rect.height,
                         resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent)
        let img: CGImage
        if let cached = symbolCache[key] { img = cached } else {
            guard let made = rasterizeSymbol(name, size: rect.size, color: resolved) else { return }
            symbolCache[key] = made
            img = made
        }
        let w = CGFloat(img.width) / 2, h = CGFloat(img.height) / 2
        let dst = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: dst.minY + dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: dst)
        ctx.restoreGState()
    }

    private func rasterizeSymbol(_ name: String, size: CGSize, color: NSColor) -> CGImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size.height * 0.8, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let sized = img.withSymbolConfiguration(config) ?? img
        let s = sized.size
        let k = min(size.width / max(s.width, 1), size.height / max(s.height, 1), 1)
        let w = max(1, Int((s.width * k * 2).rounded(.up))), h = max(1, Int((s.height * k * 2).rounded(.up)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        sized.draw(in: CGRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    func drawCorner(_ ctx: CGContext, _ L: TimelineLayout) {
        let c = L.cornerRect
        Palette.ruler.setFill(); ctx.fill(c)
        Palette.separator.setFill()
        ctx.fill(CGRect(x: c.maxX - 1, y: c.minY, width: 1, height: c.height))
        ctx.fill(CGRect(x: c.minX, y: c.maxY - 1, width: c.width, height: 1))
        let tc = TimelineTimecode.full(model.playhead, editRate: snapshot.editRate, fps: snapshot.frameRate)
        NSAttributedString(string: tc, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: Palette.text,
        ]).draw(at: CGPoint(x: c.minX + 10, y: c.minY + 6))
        drawSymbol("plus", in: addTrackButtonRect(L).insetBy(dx: 3, dy: 3), color: Palette.secondaryText)
    }

    // MARK: Playhead

    func drawPlayhead(_ ctx: CGContext, _ L: TimelineLayout) {
        let x = L.x(ofTicks: model.playhead).rounded()
        guard x >= L.metrics.headerWidth - 1, x <= bounds.maxX + 1 else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: L.metrics.headerWidth, y: 0, width: max(0, bounds.width - L.metrics.headerWidth),
                            height: bounds.height))
        Palette.playhead.setFill()
        ctx.fill(CGRect(x: x - 0.5, y: L.metrics.rulerHeight - 6, width: 1.5, height: bounds.height))
        let top = L.metrics.rulerHeight - 14
        let handle = CGMutablePath()
        handle.addRoundedRect(in: CGRect(x: x - 6, y: top - 2, width: 12.5, height: 9), cornerWidth: 2, cornerHeight: 2)
        handle.move(to: CGPoint(x: x - 6, y: top + 6))
        handle.addLine(to: CGPoint(x: x + 6.5, y: top + 6))
        handle.addLine(to: CGPoint(x: x + 0.25, y: top + 12))
        handle.closeSubpath()
        ctx.addPath(handle)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: Context menus

    func contextMenu(for hit: TimelineHit) -> NSMenu? {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ tag: Int = 0, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.tag = tag; i.isEnabled = enabled
            menu.addItem(i)
        }
        menu.autoenablesItems = false
        switch hit {
        case .clip:
            item("Split at Playhead", #selector(menuSplit(_:)), enabled: !editor.splitTargets(at: model.playhead).isEmpty)
            menu.addItem(.separator())
            item("Delete", #selector(menuDelete(_:)), enabled: !editor.deletableSelection.isEmpty)
            item("Ripple Delete", #selector(menuRippleDelete(_:)), enabled: !editor.deletableSelection.isEmpty)
        case .header(let track, _):
            item("Add Track Above", #selector(menuAddTrack(_:)), track + 1)
            item("Add Track Below", #selector(menuAddTrack(_:)), track)
            menu.addItem(.separator())
            item("Remove Track", #selector(menuRemoveTrack(_:)), track)
        case .ruler(let t):
            item("Add Marker at Playhead", #selector(menuAddMarker(_:)))
            let near = editor.marker(near: t, tolerance: layout.ticks(forWidth: 6))
            let remove = NSMenuItem(title: "Remove Marker", action: #selector(menuRemoveMarker(_:)), keyEquivalent: "")
            remove.target = self; remove.isEnabled = near != nil; remove.representedObject = near.map { NSNumber(value: $0.time) }
            menu.addItem(remove)
            menu.addItem(.separator())
            item("Zoom to Fit", #selector(menuZoomToFit(_:)))
        case .track, .empty, .corner:
            item("Add Track", #selector(menuAddTrack(_:)), snapshot.tracks.count)
            item("Zoom to Fit", #selector(menuZoomToFit(_:)))
        }
        return menu
    }

    @objc func menuSplit(_ sender: Any?) { if !editor.splitAtPlayhead() { NSSound.beep() } }
    @objc func menuDelete(_ sender: Any?) { if !editor.deleteSelection(ripple: false) { NSSound.beep() } }
    @objc func menuRippleDelete(_ sender: Any?) { if !editor.deleteSelection(ripple: true) { NSSound.beep() } }
    @objc func menuAddTrack(_ sender: NSMenuItem) { if !editor.addTrack(at: sender.tag) { NSSound.beep() } }
    @objc func menuRemoveTrack(_ sender: NSMenuItem) { if !editor.removeTrack(at: sender.tag) { NSSound.beep() } }
    @objc func menuZoomToFit(_ sender: Any?) { zoomToFit() }
    @objc func menuAddMarker(_ sender: Any?) { if !editor.addMarker(at: model.playhead) { NSSound.beep() } }
    @objc func menuRemoveMarker(_ sender: NSMenuItem) {
        guard let t = (sender.representedObject as? NSNumber)?.int64Value else { return }
        if !editor.removeMarker(near: t, tolerance: 0) { NSSound.beep() }
    }
}

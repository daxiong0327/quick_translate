import AppKit

/// The approved flowing qt supplies the app icon, window mark and menu-bar template.
@MainActor
enum BrandIcon {
  enum Style { case app, mark, menu }

  static func image(size: CGFloat, style: Style) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
      draw(in: bounds, style: style)
      return true
    }
    image.isTemplate = style != .app
    image.accessibilityDescription = "Quick Translate"
    return image
  }

  private static func draw(in bounds: NSRect, style: Style) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let transform = NSAffineTransform()
    transform.translateX(by: bounds.minX, yBy: bounds.minY)
    transform.scaleX(by: bounds.width / 100, yBy: bounds.height / 100)
    transform.concat()

    let markFrame: NSRect
    if style == .app {
      let tile = NSBezierPath(
        roundedRect: NSRect(x: 5, y: 5, width: 90, height: 90), xRadius: 21, yRadius: 21)
      NSColor(white: 0.98, alpha: 1).setFill()
      tile.fill()
      NSColor(white: 0.86, alpha: 1).setStroke()
      tile.lineWidth = 0.6
      tile.stroke()
      markFrame = NSRect(x: 17, y: 18, width: 66, height: 64)
    } else {
      // Give the small menu-bar mark most of its canvas; template tint follows system appearance.
      markFrame = NSRect(x: 3, y: 3, width: 94, height: 94)
    }

    let scale = min(markFrame.width / 575, markFrame.height / 560)
    let placement = NSAffineTransform()
    placement.translateX(
      by: markFrame.midX - 575 * scale / 2, yBy: markFrame.midY + 560 * scale / 2)
    placement.scaleX(by: scale, yBy: -scale)
    placement.translateX(by: -377, yBy: -290)
    placement.concat()
    NSColor.black.setStroke()
    drawMonogram(menu: style == .menu)
  }

  /// Centerline curves follow qt-logo-flowing-reference.png, with a continuous q descender.
  /// Small menu marks receive optical weight compensation without changing their silhouette.
  private static func drawMonogram(menu: Bool) {
    func stroke(_ path: NSBezierPath, width: CGFloat) {
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.lineWidth = menu ? max(28, width * 1.35) : width
      path.stroke()
    }

    let bowl = NSBezierPath()
    bowl.move(to: NSPoint(x: 650, y: 427))
    bowl.curve(
      to: NSPoint(x: 463, y: 451),
      controlPoint1: NSPoint(x: 607, y: 370), controlPoint2: NSPoint(x: 522, y: 396))
    bowl.curve(
      to: NSPoint(x: 391, y: 619),
      controlPoint1: NSPoint(x: 405, y: 502), controlPoint2: NSPoint(x: 373, y: 561))
    bowl.curve(
      to: NSPoint(x: 541, y: 676),
      controlPoint1: NSPoint(x: 410, y: 683), controlPoint2: NSPoint(x: 475, y: 704))
    bowl.curve(
      to: NSPoint(x: 671, y: 520),
      controlPoint1: NSPoint(x: 606, y: 649), controlPoint2: NSPoint(x: 656, y: 586))
    bowl.curve(
      to: NSPoint(x: 650, y: 427),
      controlPoint1: NSPoint(x: 682, y: 479), controlPoint2: NSPoint(x: 675, y: 452))
    bowl.close()
    stroke(bowl, width: 23)

    let descender = NSBezierPath()
    descender.move(to: NSPoint(x: 663, y: 551))
    descender.curve(
      to: NSPoint(x: 630, y: 752),
      controlPoint1: NSPoint(x: 649, y: 612), controlPoint2: NSPoint(x: 621, y: 687))
    descender.curve(
      to: NSPoint(x: 674, y: 840),
      controlPoint1: NSPoint(x: 636, y: 805), controlPoint2: NSPoint(x: 645, y: 846))
    stroke(descender, width: 23)

    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 884, y: 302))
    stem.curve(
      to: NSPoint(x: 792, y: 552),
      controlPoint1: NSPoint(x: 850, y: 365), controlPoint2: NSPoint(x: 817, y: 458))
    stem.curve(
      to: NSPoint(x: 800, y: 690),
      controlPoint1: NSPoint(x: 770, y: 632), controlPoint2: NSPoint(x: 771, y: 676))
    stem.curve(
      to: NSPoint(x: 909, y: 671),
      controlPoint1: NSPoint(x: 830, y: 713), controlPoint2: NSPoint(x: 878, y: 693))
    stroke(stem, width: 24)

    let crossbar = NSBezierPath()
    crossbar.move(to: NSPoint(x: 739, y: 452))
    crossbar.curve(
      to: NSPoint(x: 843, y: 420),
      controlPoint1: NSPoint(x: 770, y: 430), controlPoint2: NSPoint(x: 805, y: 424))
    crossbar.curve(
      to: NSPoint(x: 944, y: 398),
      controlPoint1: NSPoint(x: 888, y: 416), controlPoint2: NSPoint(x: 923, y: 410))
    stroke(crossbar, width: 14)
  }

  static func export(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
      for factor in [1, 2] {
        let name = "icon_\(size)x\(size)\(factor == 2 ? "@2x" : "").png"
        try png(pixels: size * factor, style: .app).write(
          to: directory.appendingPathComponent(name))
      }
    }
  }

  private static func png(pixels: Int, style: Style) throws -> Data {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), style: style)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return data
  }
}

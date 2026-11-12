#!/usr/bin/env swift
//
// 生成应用图标：深色圆角底 + 金色光圈。
// 用法：swift Scripts/make_icon.swift <输出 PNG 路径>
//
import AppKit
import Foundation

extension NSImage {
    /// 用给定颜色重绘模板图。
    func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect, from: rect, operation: .sourceOver, fraction: 1)
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let side: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side),
    pixelsHigh: Int(side),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("无法创建位图\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 背景
let inset = side * 0.045
let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1),
    NSColor(srgbRed: 0.06, green: 0.065, blue: 0.08, alpha: 1)
])
gradient?.draw(in: shape, angle: -90)

NSColor(white: 1, alpha: 0.07).setStroke()
shape.lineWidth = side * 0.006
shape.stroke()

// 光圈
if let symbol = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: nil),
   let configured = symbol.withSymbolConfiguration(
       NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .regular)
   ) {
    let gold = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.24, alpha: 1)
    let tinted = configured.tinted(with: gold)
    let symbolSize = tinted.size
    let origin = NSPoint(
        x: (side - symbolSize.width) / 2,
        y: (side - symbolSize.height) / 2
    )
    tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("已生成 \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("写入失败: \(error)\n".utf8))
    exit(1)
}

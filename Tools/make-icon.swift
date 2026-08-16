#!/usr/bin/env swift
//
// Generates Halo's app icon set.
//
// Kept as source rather than committed as opaque PNGs, so the icon can be
// adjusted by editing numbers and re-running:
//
//     swift Tools/make-icon.swift
//
// A deliberately plain first pass: a halo ring over a warm gradient. Worth
// replacing with a drawn icon before shipping.

import AppKit
import CoreGraphics
import Foundation

let outputDirectory = URL(fileURLWithPath: "Halo/Assets.xcassets/AppIcon.appiconset")

/// macOS wants each size at 1x and 2x.
let variants: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

func draw(pixels: Int) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let side = CGFloat(pixels)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons sit inside a rounded square with a margin, not edge to edge.
    let margin = side * 0.08
    let rect = CGRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    let corner = rect.width * 0.2237  // Apple's continuous-corner proportion
    let background = CGPath(
        roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    context.saveGState()
    context.addPath(background)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.36, green: 0.22, blue: 0.86, alpha: 1),
            CGColor(red: 0.85, green: 0.32, blue: 0.51, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: [])
    context.restoreGState()

    // The halo: an open ring, thick enough to survive at 16pt.
    let ringRadius = rect.width * 0.27
    let ringWidth = rect.width * 0.115
    let centre = CGPoint(x: rect.midX, y: rect.midY)

    context.setLineWidth(ringWidth)
    context.setLineCap(.round)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    context.addArc(
        center: centre, radius: ringRadius,
        startAngle: -.pi * 0.62, endAngle: .pi * 1.28, clockwise: false)
    context.strokePath()

    // A filled dot inside, reading as the camera bubble the ring frames.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    let dotRadius = rect.width * 0.085
    context.fillEllipse(
        in: CGRect(
            x: centre.x - dotRadius, y: centre.y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2))

    return context.makeImage()
}

var entries: [[String: String]] = []
try? FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.size * variant.scale
    guard let image = draw(pixels: pixels) else {
        print("failed at \(pixels)px")
        exit(1)
    }

    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let name = "icon_\(variant.size)x\(variant.size)\(suffix).png"

    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: variant.size, height: variant.size)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: outputDirectory.appending(path: name))

    entries.append([
        "idiom": "mac",
        "size": "\(variant.size)x\(variant.size)",
        "scale": "\(variant.scale)x",
        "filename": name,
    ])
}

let contents: [String: Any] = [
    "images": entries,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(
    withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appending(path: "Contents.json"))

print("wrote \(entries.count) icons to \(outputDirectory.path)")

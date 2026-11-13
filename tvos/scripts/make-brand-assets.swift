#!/usr/bin/env swift
// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Generates the tvOS app icon (layered) and Top Shelf images from the official chiaki-ng artwork.
// Usage: swift tvos/scripts/make-brand-assets.swift   (from the repository root)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artwork = root.appendingPathComponent("assets/official-artwork")
let brand = root.appendingPathComponent("tvos/ChiakiTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

func load(_ name: String) -> CGImage {
	let url = artwork.appendingPathComponent(name)
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
	      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
		fatalError("Cannot load \(url.path)")
	}
	return image
}

let background = load("steam capsules chiaki-ng_Library hero.png")
let logo = load("Chiaki-ng logo color.png")
let navy = CGColor(srgbRed: 0.09, green: 0.18, blue: 0.31, alpha: 1)

/// opaque: no alpha channel at all (tvOS requires this for the back icon layer and Top Shelf images)
func makeContext(_ width: Int, _ height: Int, opaque: Bool = false) -> CGContext {
	let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB)!,
		bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
	ctx.interpolationQuality = .high
	if opaque {
		ctx.setFillColor(navy)
		ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
	}
	return ctx
}

/// Scale to cover the whole canvas, centred. Slightly overscanned: the artwork has a transparent 1 px border.
func drawFill(_ image: CGImage, _ ctx: CGContext, _ width: Int, _ height: Int) {
	let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height)) * 1.02
	let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
	ctx.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
}

/// The colour logo with a soft navy glow so the lime shapes read on the lime background.
func drawLogo(_ ctx: CGContext, _ width: Int, _ height: Int, widthFraction: CGFloat, heightFraction: CGFloat) {
	let scale = min(CGFloat(width) * widthFraction / CGFloat(logo.width), CGFloat(height) * heightFraction / CGFloat(logo.height))
	let w = CGFloat(logo.width) * scale, h = CGFloat(logo.height) * scale
	let rect = CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h)
	ctx.saveGState()
	ctx.setShadow(offset: .zero, blur: h * 0.06, color: navy.copy(alpha: 0.9))
	ctx.draw(logo, in: rect)
	ctx.draw(logo, in: rect) // second pass strengthens the glow
	ctx.restoreGState()
	ctx.draw(logo, in: rect)
}

func write(_ ctx: CGContext, _ url: URL) {
	try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
	let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
	CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
	guard CGImageDestinationFinalize(dest) else { fatalError("Cannot write \(url.path)") }
	print("wrote \(url.lastPathComponent) \(ctx.width)x\(ctx.height)")
}

func writeJSON(_ object: Any, _ url: URL) {
	try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
	let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
	try! data.write(to: url)
}

let info: [String: Any] = ["author": "xcode", "version": 1]

/// Layered app icon: opaque background in Back, transparent logo in Front (tvOS adds parallax).
func makeIconStack(_ name: String, size: (Int, Int), scales: [Int]) {
	let stack = brand.appendingPathComponent("\(name).imagestack")
	writeJSON(["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]],
		stack.appendingPathComponent("Contents.json"))
	for layer in ["Front", "Back"] {
		let layerDir = stack.appendingPathComponent("\(layer).imagestacklayer")
		writeJSON(["info": info], layerDir.appendingPathComponent("Contents.json"))
		let imageset = layerDir.appendingPathComponent("Content.imageset")
		var images: [[String: Any]] = []
		for scale in scales {
			let w = size.0 * scale, h = size.1 * scale
			let ctx = makeContext(w, h, opaque: layer == "Back")
			if layer == "Back" {
				drawFill(background, ctx, w, h)
			} else {
				// Keep the logo well inside the edges: tvOS crops and moves layers when focused
				drawLogo(ctx, w, h, widthFraction: 0.66, heightFraction: 0.62)
			}
			let file = "\(layer.lowercased())\(scale > 1 ? "@\(scale)x" : "").png"
			write(ctx, imageset.appendingPathComponent(file))
			images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
		}
		writeJSON(["images": images, "info": info], imageset.appendingPathComponent("Contents.json"))
	}
}

/// Top Shelf: the banner behind the app when it sits in the top row of the Home screen.
func makeTopShelf(_ name: String, size: (Int, Int)) {
	let imageset = brand.appendingPathComponent("\(name).imageset")
	var images: [[String: Any]] = []
	for scale in [1, 2] {
		let w = size.0 * scale, h = size.1 * scale
		let ctx = makeContext(w, h, opaque: true)
		drawFill(background, ctx, w, h)
		drawLogo(ctx, w, h, widthFraction: 0.4, heightFraction: 0.5)
		let file = "topshelf-\(size.0)\(scale > 1 ? "@\(scale)x" : "").png"
		write(ctx, imageset.appendingPathComponent(file))
		images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
	}
	writeJSON(["images": images, "info": info], imageset.appendingPathComponent("Contents.json"))
}

try? FileManager.default.removeItem(at: brand)
makeIconStack("App Icon", size: (400, 240), scales: [1, 2])
makeIconStack("App Icon - App Store", size: (1280, 768), scales: [1])
makeTopShelf("Top Shelf Image", size: (1920, 720))
makeTopShelf("Top Shelf Image Wide", size: (2320, 720))
writeJSON([
	"assets": [
		["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
		["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
		["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
		["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
	],
	"info": info,
], brand.appendingPathComponent("Contents.json"))
writeJSON(["info": info], brand.deletingLastPathComponent().appendingPathComponent("Contents.json"))

// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import AVFoundation
import CoreMedia
import UIKit

/// Turns the Annex-B H.264/H.265 access units chiaki-lib hands out into CMSampleBuffers
/// and feeds them to an AVSampleBufferDisplayLayer, which decodes them in hardware.
final class VideoRenderer {
	let displayLayer = AVSampleBufferDisplayLayer()

	private let hevc: Bool
	private var formatDescription: CMVideoFormatDescription?
	private var vps: [UInt8]?
	private var sps: [UInt8]?
	private var pps: [UInt8]?
	private(set) var framesDecoded = 0

	init(hevc: Bool) {
		self.hevc = hevc
		displayLayer.videoGravity = .resizeAspect
		displayLayer.backgroundColor = UIColor.black.cgColor
		var timebase: CMTimebase?
		CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
		if let timebase {
			CMTimebaseSetTime(timebase, time: .zero)
			CMTimebaseSetRate(timebase, rate: 1.0)
			displayLayer.controlTimebase = timebase
		}
	}

	private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

	/// Called on chiaki's video thread. Returns false when the frame could not be used,
	/// which makes chiaki-lib ask the console for a new keyframe.
	func submit(_ buf: UnsafePointer<UInt8>, _ size: Int) -> Bool {
		var units: [UnsafeBufferPointer<UInt8>] = []
		var parametersChanged = false

		for nal in Self.splitAnnexB(buf, size) {
			guard let first = nal.first else { continue }
			if hevc {
				switch (first >> 1) & 0x3f {
				case 32: parametersChanged = update(&vps, nal) || parametersChanged
				case 33: parametersChanged = update(&sps, nal) || parametersChanged
				case 34: parametersChanged = update(&pps, nal) || parametersChanged
				case 35: break // access unit delimiter
				default: units.append(nal)
				}
			} else {
				switch first & 0x1f {
				case 7: parametersChanged = update(&sps, nal) || parametersChanged
				case 8: parametersChanged = update(&pps, nal) || parametersChanged
				case 9: break // access unit delimiter
				default: units.append(nal)
				}
			}
		}

		if parametersChanged || formatDescription == nil {
			formatDescription = makeFormatDescription()
		}
		guard let formatDescription else { return false }
		guard !units.isEmpty else { return true }
		guard let sample = makeSampleBuffer(units, formatDescription) else { return false }

		if renderer.status == .failed {
			LogStore.shared.append(level: 2, "Video renderer failed: \(String(describing: renderer.error)), flushing")
			renderer.flush()
			return false
		}
		renderer.enqueue(sample)
		framesDecoded += 1
		return true
	}

	func flush() {
		renderer.flush(removingDisplayedImage: true, completionHandler: nil)
	}

	private func update(_ slot: inout [UInt8]?, _ nal: UnsafeBufferPointer<UInt8>) -> Bool {
		let bytes = Array(nal)
		if slot == bytes { return false }
		slot = bytes
		return true
	}

	private func makeFormatDescription() -> CMVideoFormatDescription? {
		var sets: [[UInt8]] = []
		if hevc {
			guard let vps, let sps, let pps else { return nil }
			sets = [vps, sps, pps]
		} else {
			guard let sps, let pps else { return nil }
			sets = [sps, pps]
		}
		var result: CMVideoFormatDescription?
		let status: OSStatus = withPointers(sets) { pointers, sizes in
			if hevc {
				return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
					allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
					parameterSetPointers: pointers, parameterSetSizes: sizes,
					nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &result)
			} else {
				return CMVideoFormatDescriptionCreateFromH264ParameterSets(
					allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
					parameterSetPointers: pointers, parameterSetSizes: sizes,
					nalUnitHeaderLength: 4, formatDescriptionOut: &result)
			}
		}
		if status != noErr {
			LogStore.shared.append(level: 1, "Failed to create video format description: \(status)")
			return nil
		}
		if let result {
			let dim = CMVideoFormatDescriptionGetDimensions(result)
			LogStore.shared.append(level: 4, "Video format: \(hevc ? "H.265" : "H.264") \(dim.width)x\(dim.height)")
		}
		return result
	}

	private func withPointers<R>(_ sets: [[UInt8]], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
		let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
			let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
			p.initialize(from: set, count: set.count)
			return p
		}
		defer { buffers.forEach { $0.deallocate() } }
		let pointers = buffers.map { UnsafePointer($0) }
		let sizes = sets.map { $0.count }
		return pointers.withUnsafeBufferPointer { p in
			sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
		}
	}

	private func makeSampleBuffer(_ units: [UnsafeBufferPointer<UInt8>], _ format: CMVideoFormatDescription) -> CMSampleBuffer? {
		let total = units.reduce(0) { $0 + 4 + $1.count }
		var block: CMBlockBuffer?
		guard CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
			blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
			dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
		      let block else { return nil }

		var offset = 0
		for unit in units {
			var length = UInt32(unit.count).bigEndian
			CMBlockBufferReplaceDataBytes(with: &length, blockBuffer: block, offsetIntoDestination: offset, dataLength: 4)
			offset += 4
			CMBlockBufferReplaceDataBytes(with: unit.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: unit.count)
			offset += unit.count
		}

		var sample: CMSampleBuffer?
		var sampleSize = total
		guard CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
			sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
			sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
		      let sample else { return nil }

		if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
		   CFArrayGetCount(attachments) > 0 {
			let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
			CFDictionarySetValue(dict,
				Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
				Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
		}
		return sample
	}

	/// Splits an Annex-B byte stream into NAL units (without start codes).
	static func splitAnnexB(_ buf: UnsafePointer<UInt8>, _ size: Int) -> [UnsafeBufferPointer<UInt8>] {
		var result: [UnsafeBufferPointer<UInt8>] = []
		var start = -1
		var i = 0
		func finish(_ end: Int) {
			guard start >= 0 else { return }
			var e = end
			while e > start && buf[e - 1] == 0 { e -= 1 } // trailing zeros / 4-byte start code
			if e > start { result.append(UnsafeBufferPointer(start: buf + start, count: e - start)) }
		}
		while i + 2 < size {
			if buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1 {
				finish(i)
				i += 3
				start = i
			} else {
				i += 1
			}
		}
		if start >= 0 {
			finish(size)
		} else if size > 0 {
			// No start code at all: treat as a single NAL unit
			result.append(UnsafeBufferPointer(start: buf, count: size))
		}
		return result
	}
}

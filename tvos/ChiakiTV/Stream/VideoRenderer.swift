// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import AVFoundation
import CoreMedia
import UIKit
import VideoToolbox

/// Turns the Annex-B H.264/H.265 access units chiaki-lib hands out into frames on screen.
///
/// Frames are decoded with our own real-time VTDecompressionSession (synchronously, on chiaki's
/// video thread) and the decoded image is handed to an AVSampleBufferDisplayLayer marked
/// "display immediately". That keeps the layer from queueing compressed frames and lets us
/// measure decode time.
final class VideoRenderer {
	let displayLayer = AVSampleBufferDisplayLayer()

	private let hevc: Bool
	private var formatDescription: CMVideoFormatDescription?
	private var decompressionSession: VTDecompressionSession?
	private var vps: [UInt8]?
	private var sps: [UInt8]?
	private var pps: [UInt8]?
	private(set) var framesDecoded = 0

	// Stats, logged every few seconds (only touched on the video thread)
	private var statsStart = CACurrentMediaTime()
	private var statsFrames = 0
	private var statsDecodeTotal = 0.0
	private var statsDecodeMax = 0.0
	private var statsGapMax = 0.0
	private var statsLost = 0
	private var lastSubmit = 0.0
	private var decodeStart = 0.0

	// Smooth playback (frame pacing), video thread only. Times are host-clock seconds.
	/// When true, frames are shown on an even cadence one frame after the least-delayed frames
	/// would arrive, so a frame that arrives up to one frame late still lands on its slot.
	let smooth: Bool
	/// Frame interval: the median of recent gaps between frames (late frames don't skew it).
	/// Games often render slower than the requested stream rate.
	private var frameInterval: Double
	private var recentGaps: [Double] = []
	private var lastArrival = 0.0
	/// Frame count since the schedule was anchored, and the anchor: the earliest
	/// (arrival - count * interval) seen, i.e. the timing of the frames the network didn't delay
	private var frameCount = 0.0
	private var anchor = Double.infinity
	private var pendingLostFrames = 0
	private var statsResyncs = 0

	/// fps: the requested stream rate, used as the starting guess for the frame interval.
	init(hevc: Bool, smooth: Bool = false, fps: Int = 60) {
		self.hevc = hevc
		self.smooth = smooth
		self.frameInterval = 1.0 / Double(max(fps, 1))
		displayLayer.videoGravity = .resizeAspect
		displayLayer.backgroundColor = UIColor.black.cgColor
		if smooth {
			// Run the layer on the host clock so presentation times are host-clock times
			let clock = CMClockGetHostTimeClock()
			var timebase: CMTimebase?
			CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: clock, timebaseOut: &timebase)
			if let timebase {
				CMTimebaseSetTime(timebase, time: CMClockGetTime(clock))
				CMTimebaseSetRate(timebase, rate: 1.0)
				displayLayer.controlTimebase = timebase
			}
		}
	}

	/// Presentation time for a frame that finished decoding at `now` (see `smooth`).
	private func presentationTime(now: Double) -> Double {
		if lastArrival > 0 {
			recentGaps.append(now - lastArrival)
			if recentGaps.count > 31 { recentGaps.removeFirst() }
			let median = recentGaps.sorted()[recentGaps.count / 2]
			if recentGaps.count >= 15, median > 0.005, abs(median - frameInterval) / frameInterval > 0.1 {
				// The real frame rate differs from what the schedule assumes: re-anchor
				frameInterval = median
				anchor = .infinity
				frameCount = 0
				statsResyncs += 1
			}
		}
		lastArrival = now
		frameCount += 1 + Double(pendingLostFrames)
		pendingLostFrames = 0
		let ideal = now - frameCount * frameInterval
		if ideal < anchor {
			anchor = ideal
		} else {
			anchor += 0.0005 // follow slowly if the network delay grows for good
		}
		return max(anchor + (frameCount + 1) * frameInterval, now)
	}

	deinit {
		if let decompressionSession { VTDecompressionSessionInvalidate(decompressionSession) }
	}

	private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

	/// Called on chiaki's video thread. Returns false when the frame could not be used,
	/// which makes chiaki-lib ask the console for a new keyframe.
	func submit(_ buf: UnsafePointer<UInt8>, _ size: Int, framesLost: Int32 = 0) -> Bool {
		let now = CACurrentMediaTime()
		if lastSubmit > 0 { statsGapMax = max(statsGapMax, now - lastSubmit) }
		lastSubmit = now
		statsLost += Int(max(0, framesLost))
		pendingLostFrames += Int(max(0, framesLost))

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
			resetDecompressionSession()
		}
		guard let formatDescription else { return false }
		guard !units.isEmpty else { return true }
		guard let sample = makeSampleBuffer(units, formatDescription) else { return false }

		if decompressionSession == nil {
			makeDecompressionSession(formatDescription)
		}
		guard let decompressionSession else { return false }

		if renderer.status == .failed {
			LogStore.shared.append(level: 2, "Video renderer failed: \(String(describing: renderer.error)), flushing")
			renderer.flush()
		}

		// No kVTDecodeFrame_EnableAsynchronousDecompression: the output callback has run when this returns
		decodeStart = CACurrentMediaTime()
		let status = VTDecompressionSessionDecodeFrame(decompressionSession, sampleBuffer: sample,
			flags: [._1xRealTimePlayback], frameRefcon: nil, infoFlagsOut: nil)
		if status != noErr {
			LogStore.shared.append(level: 2, "Video decode failed: \(status)")
			if status == kVTInvalidSessionErr {
				// The session dies when the app is suspended; rebuild it on the next keyframe
				resetDecompressionSession()
			}
			return false
		}
		logStatsIfDue()
		return true
	}

	func flush() {
		renderer.flush(removingDisplayedImage: true, completionHandler: nil)
	}

	// MARK: - Decoding

	private func resetDecompressionSession() {
		if let decompressionSession {
			VTDecompressionSessionInvalidate(decompressionSession)
			self.decompressionSession = nil
		}
	}

	private func makeDecompressionSession(_ format: CMVideoFormatDescription) {
		let imageAttributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
		var callback = VTDecompressionOutputCallbackRecord(
			decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
				guard let refCon else { return }
				let renderer = Unmanaged<VideoRenderer>.fromOpaque(refCon).takeUnretainedValue()
				renderer.decoded(status: status, imageBuffer: imageBuffer)
			},
			decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
		var session: VTDecompressionSession?
		let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
			decoderSpecification: nil, imageBufferAttributes: imageAttributes as CFDictionary,
			outputCallback: &callback, decompressionSessionOut: &session)
		guard status == noErr, let session else {
			LogStore.shared.append(level: 1, "Failed to create video decoder: \(status)")
			return
		}
		VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
		decompressionSession = session
	}

	private func decoded(status: OSStatus, imageBuffer: CVImageBuffer?) {
		let decodeTime = CACurrentMediaTime() - decodeStart
		guard status == noErr, let imageBuffer else {
			if status != noErr { LogStore.shared.append(level: 2, "Video decoder error: \(status)") }
			return
		}
		var format: CMVideoFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &format)
		guard let format else { return }
		let now = CMClockGetTime(CMClockGetHostTimeClock())
		let presentation = smooth ? CMTime(seconds: presentationTime(now: now.seconds), preferredTimescale: 1_000_000_000) : now
		var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
		var sample: CMSampleBuffer?
		CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer,
			formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
		guard let sample else { return }
		if !smooth { Self.markDisplayImmediately(sample) }
		renderer.enqueue(sample)

		framesDecoded += 1
		statsFrames += 1
		statsDecodeTotal += decodeTime
		statsDecodeMax = max(statsDecodeMax, decodeTime)
	}

	private func logStatsIfDue() {
		let now = CACurrentMediaTime()
		let elapsed = now - statsStart
		guard elapsed >= 5 else { return }
		let fps = Double(statsFrames) / elapsed
		let avg = statsFrames > 0 ? statsDecodeTotal / Double(statsFrames) * 1000 : 0
		var text = String(format: "Video stats: %.1f fps, decode avg %.2f ms max %.2f ms, longest gap between frames %.1f ms, frames lost %d",
			fps, avg, statsDecodeMax * 1000, statsGapMax * 1000, statsLost)
		if smooth {
			text += String(format: ", smoothing: frame interval %.1f ms, re-anchored %d", frameInterval * 1000, statsResyncs)
			statsResyncs = 0
		}
		LogStore.shared.append(level: 4, text)
		statsStart = now
		statsFrames = 0
		statsDecodeTotal = 0
		statsDecodeMax = 0
		statsGapMax = 0
		statsLost = 0
	}

	private static func markDisplayImmediately(_ sample: CMSampleBuffer) {
		if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
		   CFArrayGetCount(attachments) > 0 {
			let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
			CFDictionarySetValue(dict,
				Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
				Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
		}
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

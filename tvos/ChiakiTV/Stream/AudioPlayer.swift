// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import AVFoundation

/// Plays the interleaved 16-bit PCM produced by chiaki-lib's Opus decoder.
/// Frames go into a small ring buffer that an AVAudioSourceNode drains, keeping latency bounded.
final class AudioPlayer {
	private let engine = AVAudioEngine()
	private var sourceNode: AVAudioSourceNode?
	private var lock = os_unfair_lock()
	private var ring: [Int16] = []
	private var readIndex = 0
	private var available = 0
	private var channels = 2
	private var maxBuffered = 0 // samples (all channels)
	private var started = false

	/// Called from chiaki's audio thread when the stream's audio format is known.
	func configure(channels: Int, rate: Int) {
		DispatchQueue.main.async { self.setup(channels: channels, rate: rate) }
	}

	private func setup(channels: Int, rate: Int) {
		stop()
		let session = AVAudioSession.sharedInstance()
		do {
			try session.setCategory(.playback, mode: .default, options: [])
			try session.setPreferredIOBufferDuration(0.005)
			try session.setActive(true)
		} catch {
			LogStore.shared.append(level: 2, "AVAudioSession setup failed: \(error)")
		}

		os_unfair_lock_lock(&lock)
		self.channels = channels
		ring = [Int16](repeating: 0, count: rate * channels) // 1 s capacity
		readIndex = 0
		available = 0
		maxBuffered = rate * channels / 10 // keep at most ~100 ms queued
		os_unfair_lock_unlock(&lock)

		guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)) else { return }
		let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, audioBufferList in
			self.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(audioBufferList))
			return noErr
		}
		sourceNode = node
		engine.attach(node)
		engine.connect(node, to: engine.mainMixerNode, format: format)
		do {
			try engine.start()
			started = true
			LogStore.shared.append(level: 4, "Audio: \(channels) ch @ \(rate) Hz")
		} catch {
			LogStore.shared.append(level: 1, "Audio engine failed to start: \(error)")
		}
	}

	func stop() {
		if started {
			engine.stop()
			started = false
		}
		if let sourceNode {
			engine.detach(sourceNode)
			self.sourceNode = nil
		}
	}

	/// Called from chiaki's audio thread. count = frames (samples per channel).
	func push(_ samples: UnsafePointer<Int16>, frames: Int) {
		os_unfair_lock_lock(&lock)
		defer { os_unfair_lock_unlock(&lock) }
		let capacity = ring.count
		guard capacity > 0 else { return }
		let n = min(frames * channels, capacity)
		ring.withUnsafeMutableBufferPointer { r in
			var write = (readIndex + available) % capacity
			for i in 0..<n {
				r[write] = samples[i]
				write += 1
				if write == capacity { write = 0 }
			}
		}
		available += n
		if available > maxBuffered {
			// Drop the oldest audio so we never lag behind the video
			let drop = available - maxBuffered / 2
			readIndex = (readIndex + drop) % capacity
			available -= drop
		}
	}

	private func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
		os_unfair_lock_lock(&lock)
		defer { os_unfair_lock_unlock(&lock) }
		let ch = channels
		let capacity = ring.count
		let framesAvailable = capacity > 0 ? available / ch : 0
		let framesToCopy = min(frameCount, framesAvailable)
		ring.withUnsafeBufferPointer { r in
			for (c, buffer) in buffers.enumerated() {
				guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
				var idx = readIndex + min(c, ch - 1)
				for f in 0..<frameCount {
					if f < framesToCopy {
						out[f] = Float(r[idx % capacity]) / 32768.0
						idx += ch
					} else {
						out[f] = 0
					}
				}
			}
		}
		if framesToCopy > 0 {
			readIndex = (readIndex + framesToCopy * ch) % capacity
			available -= framesToCopy * ch
		}
	}
}

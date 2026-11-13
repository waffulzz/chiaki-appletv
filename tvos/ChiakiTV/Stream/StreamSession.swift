// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import ChiakiTVBridge

/// One Remote Play connection: owns the chiaki session plus the video/audio sinks it feeds.
final class StreamSession {
	enum Event {
		case connected
		case loginPINRequested(incorrect: Bool)
		case quit(error: Bool, reason: String)
	}

	let video: VideoRenderer
	let audio = AudioPlayer()
	var onEvent: ((Event) -> Void)? // main thread
	var onRumble: ((UInt8, UInt8) -> Void)? // main thread

	private var handle: OpaquePointer?
	private let console: RegisteredConsole
	private let address: String
	private let settings: (resolution: Resolution, fps: Int, codec: VideoCodec, bitrate: UInt32)
	var fps: Int { settings.fps }
	var videoSize: (width: UInt32, height: UInt32) { settings.resolution.size }
	var isHEVC: Bool { settings.codec == .h265 }

	init(console: RegisteredConsole, address: String, settings: StreamSettings) {
		self.console = console
		self.address = address
		let codec: VideoCodec = console.isPS5 ? settings.codec : .h264
		self.settings = (settings.resolution, settings.fps, codec, settings.effectiveBitrate)
		self.video = VideoRenderer(hevc: codec == .h265)
	}

	deinit {
		if handle != nil {
			LogStore.shared.append(level: 2, "StreamSession deallocated while running")
		}
	}

	func start() -> Bool {
		var info = ChiakiTVConnectInfo()
		info.ps5 = console.isPS5
		copyBytes(console.registKey, into: &info.regist_key)
		copyBytes(console.rpKey, into: &info.morning)
		let size = settings.resolution.size
		info.width = size.width
		info.height = size.height
		info.max_fps = UInt32(settings.fps)
		info.bitrate = settings.bitrate
		info.codec = Int32(settings.codec.rawValue)
		info.enable_dualsense = true

		var callbacks = ChiakiTVCallbacks()
		callbacks.video = { buf, size, framesLost, _, user in
			guard let buf, let user else { return false }
			let s = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			return s.video.submit(buf, size, framesLost: framesLost)
		}
		callbacks.audio_settings = { channels, rate, user in
			guard let user else { return }
			Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue().audio.configure(channels: Int(channels), rate: Int(rate))
		}
		callbacks.audio_frame = { buf, count, user in
			guard let buf, let user else { return }
			Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue().audio.push(buf, frames: count)
		}
		callbacks.event = { eventPtr, user in
			guard let e = eventPtr?.pointee, let user else { return }
			let s = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			switch e.type {
			case Int32(CHIAKITV_EVENT_CONNECTED.rawValue):
				DispatchQueue.main.async { s.onEvent?(.connected) }
			case Int32(CHIAKITV_EVENT_LOGIN_PIN_REQUEST.rawValue):
				let incorrect = e.pin_incorrect
				DispatchQueue.main.async { s.onEvent?(.loginPINRequested(incorrect: incorrect)) }
			case Int32(CHIAKITV_EVENT_QUIT.rawValue):
				let reason = e.quit_reason_str.map { String(cString: $0) } ?? "Unknown"
				let isError = e.quit_is_error
				DispatchQueue.main.async { s.onEvent?(.quit(error: isError, reason: reason)) }
			case Int32(CHIAKITV_EVENT_RUMBLE.rawValue):
				let l = e.rumble_left, r = e.rumble_right
				DispatchQueue.main.async { s.onRumble?(l, r) }
			default:
				break
			}
		}
		// Balanced in stop(): the session keeps us alive until chiaki's threads are joined
		callbacks.user = Unmanaged.passRetained(self).toOpaque()

		handle = address.withCString { host -> OpaquePointer? in
			info.host = host
			return chiakitv_session_start(&info, &callbacks)
		}
		if handle == nil {
			Unmanaged.passUnretained(self).release()
			return false
		}
		return true
	}

	func setControllerState(_ state: ChiakiControllerState) {
		guard let handle else { return }
		var s = state
		chiakitv_session_set_controller_state(handle, &s)
	}

	func setLoginPIN(_ pin: String) {
		guard let handle else { return }
		pin.withCString { chiakitv_session_set_login_pin(handle, $0) }
	}

	/// Puts the console into rest mode, then disconnects.
	func sleepConsole() {
		guard let handle else { return }
		chiakitv_session_goto_bed(handle)
	}

	/// Tears the session down on a background queue.
	func stop(completion: (() -> Void)? = nil) {
		guard let h = handle else { completion?(); return }
		handle = nil
		chiakitv_session_stop(h)
		DispatchQueue.global(qos: .userInitiated).async {
			chiakitv_session_free(h)
			DispatchQueue.main.async {
				self.audio.stop()
				Unmanaged.passUnretained(self).release()
				completion?()
			}
		}
	}
}

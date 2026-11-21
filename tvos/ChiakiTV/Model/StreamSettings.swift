// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import ChiakiTVBridge

enum Resolution: Int, CaseIterable, Identifiable, Codable {
	case p360 = 1, p540 = 2, p720 = 3, p1080 = 4
	var id: Int { rawValue }
	var label: String {
		switch self {
		case .p360: return "360p"
		case .p540: return "540p"
		case .p720: return "720p"
		case .p1080: return "1080p"
		}
	}
	var size: (width: UInt32, height: UInt32) {
		switch self {
		case .p360: return (640, 360)
		case .p540: return (960, 540)
		case .p720: return (1280, 720)
		case .p1080: return (1920, 1080)
		}
	}
	/// Same defaults as chiaki_connect_video_profile_preset()
	var defaultBitrate: UInt32 {
		switch self {
		case .p360: return 2000
		case .p540: return 6000
		case .p720: return 10000
		case .p1080: return 15000
		}
	}
}

enum VideoCodec: Int, CaseIterable, Identifiable, Codable {
	case h264 = 0, h265 = 1
	var id: Int { rawValue }
	var label: String { self == .h264 ? "H.264" : "H.265 (PS5 only)" }
}

/// Which touchpad input reaches the console. Over Remote Play the PS5 treats touches as touchpad
/// clicks in some games (GTA 6 opens its map; chiaki-ng issue #894), so by default only clicks are sent.
enum TouchpadMode: Int, CaseIterable, Identifiable {
	case clicksOnly = 0, clicksAndSwipes = 1, allTouches = 2
	var id: Int { rawValue }
	var label: String {
		switch self {
		case .clicksOnly: return "Clicks only"
		case .clicksAndSwipes: return "Clicks and swipes"
		case .allTouches: return "All touches"
		}
	}
}

/// User-facing stream settings, persisted in UserDefaults.
final class StreamSettings: ObservableObject {
	private let defaults = UserDefaults.standard

	@Published var resolution: Resolution { didSet { defaults.set(resolution.rawValue, forKey: "resolution") } }
	@Published var fps: Int { didSet { defaults.set(fps, forKey: "fps") } }
	@Published var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: "codec") } }
	@Published var bitrate: Int { didSet { defaults.set(bitrate, forKey: "bitrate") } } // 0 = automatic
	@Published var psnAccountID: String { didSet { defaults.set(psnAccountID, forKey: "psnAccountID") } }
	@Published var touchpadMode: TouchpadMode { didSet { defaults.set(touchpadMode.rawValue, forKey: "touchpadMode") } }

	init() {
		resolution = Resolution(rawValue: defaults.integer(forKey: "resolution")) ?? .p1080
		let storedFPS = defaults.integer(forKey: "fps")
		fps = storedFPS == 30 ? 30 : 60
		// integer(forKey:) reads an unset key as 0 (H.264), so check presence explicitly
		codec = (defaults.object(forKey: "codec") as? Int).flatMap(VideoCodec.init(rawValue:)) ?? .h265
		bitrate = defaults.integer(forKey: "bitrate")
		psnAccountID = defaults.string(forKey: "psnAccountID") ?? ""
		touchpadMode = TouchpadMode(rawValue: defaults.integer(forKey: "touchpadMode")) ?? .clicksOnly
	}

	var effectiveBitrate: UInt32 { bitrate > 0 ? UInt32(bitrate) : resolution.defaultBitrate }
}

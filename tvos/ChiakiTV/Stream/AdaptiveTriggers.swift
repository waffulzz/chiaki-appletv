// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import GameController

/// Applies PS5 adaptive trigger effects to a DualSense through GameController.
///
/// The console sends each effect as a type byte plus 10 parameter bytes in the DualSense's own
/// output report format (desktop chiaki-ng forwards those bytes to the controller as-is). tvOS
/// apps cannot send raw reports, so each format is translated to the closest
/// GCDualSenseAdaptiveTrigger mode. Positions use the controller's 10 trigger zones.
enum AdaptiveTriggers {
	/// Returns a short description of what was applied, for the log.
	@discardableResult
	static func apply(type: UInt8, params p: [UInt8], to trigger: GCDualSenseAdaptiveTrigger) -> String {
		guard p.count >= 10 else { return "invalid" }
		switch type {
		case 0x00, 0x05: // off / reset
			trigger.setModeOff()
			return "off"

		case 0x21: // feedback: zone mask + 3-bit strength per zone
			let mask = zoneMask(p), strengths = packed(p, at: 2)
			var values = [Float](repeating: 0, count: zoneCount)
			for zone in 0..<zoneCount where mask & (1 << zone) != 0 {
				values[zone] = Float((strengths >> (3 * zone)) & 7 + 1) / 8
			}
			trigger.setModeFeedback(resistiveStrengths: resistiveStrengths(values))
			return "feedback \(values.map { String(format: "%.2f", $0) }.joined(separator: " "))"

		case 0x25: // weapon: start and end zones + strength
			guard let (start, end) = startEnd(p) else { trigger.setModeOff(); return "weapon (invalid zones)" }
			let strength = Float(p[2] & 7 + 1) / 8
			trigger.setModeWeaponWithStartPosition(position(start), endPosition: position(end), resistiveStrength: strength)
			return "weapon \(start)-\(end) strength \(strength)"

		case 0x26: // vibration: zone mask + 3-bit amplitude per zone + frequency
			let mask = zoneMask(p), amplitudes = packed(p, at: 2)
			var values = [Float](repeating: 0, count: zoneCount)
			for zone in 0..<zoneCount where mask & (1 << zone) != 0 {
				values[zone] = Float((amplitudes >> (3 * zone)) & 7 + 1) / 8
			}
			let frequency = Float(p[8]) / 255
			trigger.setModeVibration(amplitudes: positionalAmplitudes(values), frequency: frequency)
			return "vibration freq \(p[8])"

		case 0x22: // bow: start/end zones, strength, snap force; closest is weapon
			guard let (start, end) = startEnd(p) else { trigger.setModeOff(); return "bow (invalid zones)" }
			let strength = Float(p[2] & 7 + 1) / 8
			trigger.setModeWeaponWithStartPosition(position(start), endPosition: position(end), resistiveStrength: strength)
			return "bow as weapon \(start)-\(end)"

		case 0x23: // galloping: rhythmic pulses from the start zone; closest is vibration
			let start = startEnd(p)?.0 ?? 0
			trigger.setModeVibrationWithStartPosition(position(start), amplitude: 0.6, frequency: Float(p[3]) / 255)
			return "galloping as vibration from \(start)"

		case 0x27: // machine: alternating amplitudes A/B from the start zone; closest is vibration
			let start = startEnd(p)?.0 ?? 0
			let amplitude = Float(max(p[2] & 7, (p[2] >> 3) & 7)) / 7
			trigger.setModeVibrationWithStartPosition(position(start), amplitude: amplitude, frequency: Float(p[3]) / 255)
			return "machine as vibration from \(start)"

		case 0x01: // simple feedback: position, strength (0-255)
			trigger.setModeFeedbackWithStartPosition(Float(p[0]) / 255, resistiveStrength: Float(p[1]) / 255)
			return "simple feedback"

		case 0x02: // simple weapon: start, end, strength (0-255)
			guard p[1] > p[0] else { trigger.setModeOff(); return "simple weapon (invalid)" }
			trigger.setModeWeaponWithStartPosition(Float(p[0]) / 255, endPosition: Float(p[1]) / 255, resistiveStrength: Float(p[2]) / 255)
			return "simple weapon"

		case 0x06: // simple vibration: frequency, amplitude, position
			trigger.setModeVibrationWithStartPosition(Float(p[2]) / 255, amplitude: Float(p[1]) / 255, frequency: Float(p[0]) / 255)
			return "simple vibration"

		case 0x11: // limited feedback: position (0-9), strength (0-10)
			trigger.setModeFeedbackWithStartPosition(position(Int(min(p[0], 9))), resistiveStrength: Float(min(p[1], 10)) / 10)
			return "limited feedback"

		case 0x12: // limited weapon: start, end (0-255), strength (0-10)
			guard p[1] > p[0] else { trigger.setModeOff(); return "limited weapon (invalid)" }
			trigger.setModeWeaponWithStartPosition(Float(p[0]) / 255, endPosition: Float(p[1]) / 255, resistiveStrength: Float(min(p[2], 10)) / 10)
			return "limited weapon"

		default:
			trigger.setModeOff()
			return String(format: "unknown type 0x%02x (off)", type)
		}
	}

	static func reset(_ gamepad: GCExtendedGamepad?) {
		guard let ds = gamepad as? GCDualSenseGamepad else { return }
		ds.leftTrigger.setModeOff()
		ds.rightTrigger.setModeOff()
	}

	// MARK: - Helpers

	private static let zoneCount = 10

	private static func position(_ zone: Int) -> Float { Float(zone) / Float(zoneCount - 1) }

	private static func zoneMask(_ p: [UInt8]) -> UInt16 { UInt16(p[0]) | UInt16(p[1]) << 8 }

	private static func packed(_ p: [UInt8], at i: Int) -> UInt32 {
		UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
	}

	/// Lowest and highest zone set in the mask (start and end of the effect).
	private static func startEnd(_ p: [UInt8]) -> (Int, Int)? {
		let mask = zoneMask(p)
		guard mask != 0 else { return nil }
		let start = mask.trailingZeroBitCount
		let end = 15 - mask.leadingZeroBitCount
		guard end > start, end < 16 else { return nil }
		return (start, min(end, zoneCount - 1))
	}

	private static func resistiveStrengths(_ v: [Float]) -> GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths {
		var s = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
		withUnsafeMutableBytes(of: &s.values) { raw in
			let floats = raw.bindMemory(to: Float.self)
			for i in 0..<min(v.count, floats.count) { floats[i] = v[i] }
		}
		return s
	}

	private static func positionalAmplitudes(_ v: [Float]) -> GCDualSenseAdaptiveTrigger.PositionalAmplitudes {
		var a = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
		withUnsafeMutableBytes(of: &a.values) { raw in
			let floats = raw.bindMemory(to: Float.self)
			for i in 0..<min(v.count, floats.count) { floats[i] = v[i] }
		}
		return a
	}
}

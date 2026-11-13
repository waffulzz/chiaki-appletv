// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import GameController
import CoreHaptics
import ChiakiTVBridge

/// Maps a GameController gamepad (DualSense, DualShock 4, Xbox, MFi) onto ChiakiControllerState.
///
/// System gestures on the controller (Home/PS, Create long-press) are switched off while
/// streaming, which Apple allows for game streaming apps. If tvOS still keeps the PS button:
///  - Options + Share (Create) together sends the PS button
///  - L1 + R1 + L3 + R3 together asks to end the stream
final class ControllerInput {
	var onStateChange: ((ChiakiControllerState) -> Void)?
	var onQuitRequested: (() -> Void)?
	/// Touchpad coordinates differ between the PS5 (DualSense) and PS4 (DualShock 4)
	var isPS5 = true

	private var controller: GCController?
	/// Controller callbacks run here instead of the main queue, so input is never stuck behind UI work.
	/// lastState and quitComboArmed are only touched on this queue.
	private let inputQueue = DispatchQueue(label: "chiaki.controller-input", qos: .userInteractive)
	private var remotes: [GCController] = []
	private var lastState = ChiakiControllerState()
	/// False while one of our menus is on screen: input then drives the menu, not the console
	private var forwarding = true
	private var quitComboArmed = true
	private var observers: [NSObjectProtocol] = []
	// Touchpad (input queue only): touches and touch_id_next live here between updates
	private var touchState = ChiakiControllerState()
	private var touchIDs: [Int8] = [-1, -1]
	/// A mute/microphone button, if the controller exposes one, acts as the PS button
	private var extraPSPressed = false
	private var gestureElements: [GCControllerElement] = []
	// Rumble (main queue only)
	private var hapticEngines: [CHHapticEngine] = []
	// Standard players only: on tvOS 26+ the haptics service refuses advanced players (error 4097)
	private var rumblePlayers: [CHHapticPatternPlayer] = []
	private var rumblePlaying: [Bool] = []
	private var lastHapticsAttempt: CFTimeInterval = 0

	init() {
		chiaki_controller_state_set_idle(&lastState)
		chiaki_controller_state_set_idle(&touchState)
		let nc = NotificationCenter.default
		observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
			guard let self, let c = note.object as? GCController else { return }
			if c.extendedGamepad != nil && self.controller == nil { self.attach(c) }
		})
		observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
			guard let self, let c = note.object as? GCController, c === self.controller else { return }
			self.detach()
			if let next = GCController.controllers().first(where: { $0.extendedGamepad != nil }) { self.attach(next) }
		})
		observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
			if let c = note.object as? GCController { self?.watchRemote(c) }
		})
		GCController.controllers().forEach(watchRemote)
		if let c = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
			attach(c)
		}
	}

	/// The Siri Remote's Back button ends the stream, whichever gamepad is playing.
	private func watchRemote(_ c: GCController) {
		guard c.extendedGamepad == nil, let micro = c.microGamepad, !remotes.contains(where: { $0 === c }) else { return }
		remotes.append(c)
		micro.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
			if pressed { self?.onQuitRequested?() }
		}
	}

	deinit {
		LogStore.shared.append(level: 16, "ControllerInput released")
		observers.forEach { NotificationCenter.default.removeObserver($0) }
		detach()
		for r in remotes { r.microGamepad?.buttonMenu.pressedChangedHandler = nil }
	}

	var controllerName: String? { controller?.vendorName }

	private func attach(_ c: GCController) {
		detach()
		controller = c
		LogStore.shared.append(level: 4, "Controller: \(c.vendorName ?? "unknown") (\(c.extendedGamepad != nil ? "extended" : "micro"))")
		guard let gp = c.extendedGamepad else { return }
		disableSystemGestures(c)
		c.handlerQueue = inputQueue
		gp.valueChangedHandler = { [weak self] gp, element in self?.update(gp, element: element) }
	}

	private func detach() {
		controller?.extendedGamepad?.valueChangedHandler = nil
		controller?.handlerQueue = .main
		for e in gestureElements { e.preferredSystemGestureState = .enabled }
		gestureElements.removeAll()
		controller = nil
		stopHaptics()
	}

	/// Let the PS/Home and Create buttons reach the console instead of tvOS gestures
	/// (Control Center, screenshots). Apple documents this for game streaming apps.
	private func disableSystemGestures(_ c: GCController) {
		let profile = c.physicalInputProfile
		var names: [String] = []
		for element in profile.allElements where element.isBoundToSystemGesture {
			element.preferredSystemGestureState = .disabled
			gestureElements.append(element)
			names.append(element.localizedName ?? element.unmappedLocalizedName ?? "?")
		}
		LogStore.shared.append(level: 4, "Controller system gestures disabled for: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
		LogStore.shared.append(level: 4, "Controller buttons: \(profile.buttons.keys.sorted().joined(separator: ", "))")
	}

	private static let knownButtonNames: Set<String> = [
		GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY, GCInputButtonMenu, GCInputButtonOptions,
		GCInputButtonHome, GCInputButtonShare, GCInputLeftShoulder, GCInputRightShoulder, GCInputLeftTrigger,
		GCInputRightTrigger, GCInputLeftThumbstickButton, GCInputRightThumbstickButton, GCInputDualShockTouchpadButton,
	]

	/// Logs buttons outside the standard set (to spot e.g. a mute button) and maps a mute/microphone one to PS.
	private func handleExtraButton(_ element: GCControllerElement) {
		guard let button = element as? GCControllerButtonInput else { return }
		let names = button.aliases
		guard names.isDisjoint(with: Self.knownButtonNames) else { return }
		let label = names.sorted().joined(separator: "/")
		if button.isPressed { LogStore.shared.append(level: 4, "Controller: extra button pressed: \(label)") }
		if names.contains(where: { $0.localizedCaseInsensitiveContains("mute") || $0.localizedCaseInsensitiveContains("microphone") }) {
			extraPSPressed = button.isPressed
		}
	}

	private func update(_ gp: GCExtendedGamepad, element: GCControllerElement) {
		handleExtraButton(element)
		updateTouches(gp)
		var s = ChiakiControllerState()
		chiaki_controller_state_set_idle(&s)
		var buttons: UInt32 = 0
		func map(_ input: GCControllerButtonInput?, _ button: chiaki_controller_button_t) {
			if input?.isPressed == true { buttons |= button.rawValue }
		}
		map(gp.buttonA, CHIAKI_CONTROLLER_BUTTON_CROSS)
		map(gp.buttonB, CHIAKI_CONTROLLER_BUTTON_MOON)
		map(gp.buttonX, CHIAKI_CONTROLLER_BUTTON_BOX)
		map(gp.buttonY, CHIAKI_CONTROLLER_BUTTON_PYRAMID)
		map(gp.dpad.left, CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT)
		map(gp.dpad.right, CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT)
		map(gp.dpad.up, CHIAKI_CONTROLLER_BUTTON_DPAD_UP)
		map(gp.dpad.down, CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN)
		map(gp.leftShoulder, CHIAKI_CONTROLLER_BUTTON_L1)
		map(gp.rightShoulder, CHIAKI_CONTROLLER_BUTTON_R1)
		map(gp.leftThumbstickButton, CHIAKI_CONTROLLER_BUTTON_L3)
		map(gp.rightThumbstickButton, CHIAKI_CONTROLLER_BUTTON_R3)
		let options = gp.buttonMenu.isPressed
		let share = gp.buttonOptions?.isPressed == true
		if options && share {
			buttons |= CHIAKI_CONTROLLER_BUTTON_PS.rawValue
		} else {
			if options { buttons |= CHIAKI_CONTROLLER_BUTTON_OPTIONS.rawValue }
			if share { buttons |= CHIAKI_CONTROLLER_BUTTON_SHARE.rawValue }
		}
		if gp.buttonHome?.isPressed == true || extraPSPressed { buttons |= CHIAKI_CONTROLLER_BUTTON_PS.rawValue }
		if let ds = gp as? GCDualSenseGamepad, ds.touchpadButton.isPressed {
			buttons |= CHIAKI_CONTROLLER_BUTTON_TOUCHPAD.rawValue
		} else if let ds4 = gp as? GCDualShockGamepad, ds4.touchpadButton.isPressed {
			buttons |= CHIAKI_CONTROLLER_BUTTON_TOUCHPAD.rawValue
		}
		s.buttons = buttons
		s.l2_state = UInt8(max(0, min(255, gp.leftTrigger.value * 255)))
		s.r2_state = UInt8(max(0, min(255, gp.rightTrigger.value * 255)))
		s.left_x = Self.axis(gp.leftThumbstick.xAxis.value)
		s.left_y = Self.axis(-gp.leftThumbstick.yAxis.value)
		s.right_x = Self.axis(gp.rightThumbstick.xAxis.value)
		s.right_y = Self.axis(-gp.rightThumbstick.yAxis.value)
		s.touches = touchState.touches
		s.touch_id_next = touchState.touch_id_next

		let quitCombo = CHIAKI_CONTROLLER_BUTTON_L1.rawValue | CHIAKI_CONTROLLER_BUTTON_R1.rawValue
			| CHIAKI_CONTROLLER_BUTTON_L3.rawValue | CHIAKI_CONTROLLER_BUTTON_R3.rawValue
		if buttons & quitCombo == quitCombo {
			if quitComboArmed {
				quitComboArmed = false
				DispatchQueue.main.async { [weak self] in self?.onQuitRequested?() }
			}
		} else {
			quitComboArmed = true
		}

		guard forwarding else { return }
		if !chiaki_controller_state_equals(&s, &lastState) {
			lastState = s
			onStateChange?(s)
		}
	}

	/// DualSense/DualShock touchpad fingers (-1...1, y up) to PS touchpad touches.
	/// GameController reports (0, 0) when a finger is lifted.
	private func updateTouches(_ gp: GCExtendedGamepad) {
		let pads: [GCControllerDirectionPad]
		if let ds = gp as? GCDualSenseGamepad {
			pads = [ds.touchpadPrimary, ds.touchpadSecondary]
		} else if let ds4 = gp as? GCDualShockGamepad {
			pads = [ds4.touchpadPrimary, ds4.touchpadSecondary]
		} else {
			return
		}
		let maxX: Float = isPS5 ? 1919 : 1920
		let maxY: Float = isPS5 ? 1079 : 942
		for (i, pad) in pads.enumerated() {
			let x = pad.xAxis.value, y = pad.yAxis.value
			let px = UInt16(max(0, min(maxX, (x + 1) / 2 * maxX)))
			let py = UInt16(max(0, min(maxY, (1 - y) / 2 * maxY)))
			if x != 0 || y != 0 {
				if touchIDs[i] < 0 {
					touchIDs[i] = chiaki_controller_state_start_touch(&touchState, px, py)
				} else {
					chiaki_controller_state_set_touch_pos(&touchState, UInt8(touchIDs[i]), px, py)
				}
			} else if touchIDs[i] >= 0 {
				chiaki_controller_state_stop_touch(&touchState, UInt8(touchIDs[i]))
				touchIDs[i] = -1
			}
		}
	}

	/// Stop or resume sending input to the console. Stopping sends an idle state, so nothing
	/// stays held on the console (e.g. the buttons used to open the menu).
	func setForwarding(_ on: Bool) {
		inputQueue.async { [weak self] in
			guard let self, self.forwarding != on else { return }
			self.forwarding = on
			var idle = ChiakiControllerState()
			chiaki_controller_state_set_idle(&idle)
			self.lastState = idle
			self.onStateChange?(idle)
		}
	}

	private static func axis(_ v: Float) -> Int16 {
		Int16(max(-1, min(1, v)) * 32767)
	}

	// MARK: - Rumble

	/// Engines are created on the first rumble rather than at attach time, and creation is
	/// retried: the controller haptics service is not always reachable right away.
	private func startHaptics() {
		guard let c = controller, let haptics = c.haptics else { return }
		let now = CACurrentMediaTime()
		guard now - lastHapticsAttempt > 2 else { return }
		lastHapticsAttempt = now
		let supported = haptics.supportedLocalities
		LogStore.shared.append(level: 4, "Haptics: supported localities \(supported.map { $0.rawValue }.sorted())")
		var candidates: [[GCHapticsLocality]] = []
		if supported.contains(.leftHandle) && supported.contains(.rightHandle) { candidates.append([.leftHandle, .rightHandle]) }
		if supported.contains(.handles) { candidates.append([.handles]) }
		candidates.append([.default])
		for localities in candidates {
			var engines: [CHHapticEngine] = []
			var players: [CHHapticPatternPlayer] = []
			do {
				for locality in localities {
					guard let engine = haptics.createEngine(withLocality: locality) else { throw CocoaError(.featureUnsupported) }
					engine.playsHapticsOnly = true
					engine.isAutoShutdownEnabled = false
					engine.stoppedHandler = { [weak self] reason in
						LogStore.shared.append(level: 2, "Haptics engine stopped: \(reason.rawValue)")
						DispatchQueue.main.async { self?.stopHaptics() }
					}
					engine.resetHandler = { [weak self] in DispatchQueue.main.async { self?.stopHaptics() } }
					try engine.start()
					let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
						CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
						CHHapticEventParameter(parameterID: .hapticSharpness, value: locality == .rightHandle ? 0.8 : 0.3),
					], relativeTime: 0, duration: 1000)
					players.append(try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])))
					engines.append(engine)
				}
				hapticEngines = engines
				rumblePlayers = players
				rumblePlaying = Array(repeating: false, count: players.count)
				LogStore.shared.append(level: 4, "Haptics: ready (\(localities.map { $0.rawValue }.joined(separator: ", ")))")
				return
			} catch {
				engines.forEach { $0.stop() }
				LogStore.shared.append(level: 2, "Haptics: \(localities.map { $0.rawValue }.joined(separator: ", ")) failed: \(error)")
			}
		}
	}

	private func stopHaptics() {
		rumblePlayers.removeAll()
		rumblePlaying.removeAll()
		hapticEngines.forEach { $0.stop() }
		hapticEngines.removeAll()
	}

	/// left = low frequency (left handle), right = high frequency (right handle), 0...255. Main queue.
	func rumble(left: UInt8, right: UInt8) {
		if rumblePlayers.isEmpty {
			guard left > 0 || right > 0 else { return }
			startHaptics()
		}
		for (i, player) in rumblePlayers.enumerated() {
			// One engine (both handles): follow the stronger motor
			let raw = rumblePlayers.count == 1 ? max(left, right) : (i == 0 ? left : right)
			let value = Float(raw) / 255
			do {
				if value <= 0 {
					if rumblePlaying[i] {
						try player.stop(atTime: CHHapticTimeImmediate)
						rumblePlaying[i] = false
					}
				} else {
					try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)], atTime: CHHapticTimeImmediate)
					if !rumblePlaying[i] {
						try player.start(atTime: CHHapticTimeImmediate)
						rumblePlaying[i] = true
					}
				}
			} catch {
				LogStore.shared.append(level: 2, "Haptics: playback failed: \(error)")
				stopHaptics()
				return
			}
		}
	}
}

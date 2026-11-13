// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import GameController
import CoreHaptics
import ChiakiTVBridge

/// Maps a GameController gamepad (DualSense, DualShock 4, Xbox, MFi) onto ChiakiControllerState.
///
/// tvOS reserves the controller's Home/PS button for the system, so:
///  - Options + Share (Create) together sends the PS button
///  - L1 + R1 + L3 + R3 together asks to end the stream
final class ControllerInput {
	var onStateChange: ((ChiakiControllerState) -> Void)?
	var onQuitRequested: (() -> Void)?

	private var controller: GCController?
	/// Controller callbacks run here instead of the main queue, so input is never stuck behind UI work.
	/// lastState and quitComboArmed are only touched on this queue.
	private let inputQueue = DispatchQueue(label: "chiaki.controller-input", qos: .userInteractive)
	private var remotes: [GCController] = []
	private var lastState = ChiakiControllerState()
	private var quitComboArmed = true
	private var observers: [NSObjectProtocol] = []
	private var hapticEngines: [CHHapticEngine] = []
	private var rumblePlayers: [CHHapticAdvancedPatternPlayer] = []

	init() {
		chiaki_controller_state_set_idle(&lastState)
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
		c.handlerQueue = inputQueue
		gp.valueChangedHandler = { [weak self] gp, _ in self?.update(gp) }
		setupHaptics(c)
	}

	private func detach() {
		controller?.extendedGamepad?.valueChangedHandler = nil
		controller?.handlerQueue = .main
		controller = nil
		rumblePlayers.removeAll()
		hapticEngines.forEach { $0.stop() }
		hapticEngines.removeAll()
	}

	private func update(_ gp: GCExtendedGamepad) {
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
		if gp.buttonHome?.isPressed == true { buttons |= CHIAKI_CONTROLLER_BUTTON_PS.rawValue }
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

		if !chiaki_controller_state_equals(&s, &lastState) {
			lastState = s
			onStateChange?(s)
		}
	}

	private static func axis(_ v: Float) -> Int16 {
		Int16(max(-1, min(1, v)) * 32767)
	}

	// MARK: - Rumble

	private func setupHaptics(_ c: GCController) {
		guard let haptics = c.haptics else { return }
		for locality in [GCHapticsLocality.leftHandle, .rightHandle] {
			guard haptics.supportedLocalities.contains(locality),
			      let engine = haptics.createEngine(withLocality: locality) else { continue }
			do {
				try engine.start()
				let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
					CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
				], relativeTime: 0, duration: 100)
				let pattern = try CHHapticPattern(events: [event], parameters: [])
				let player = try engine.makeAdvancedPlayer(with: pattern)
				hapticEngines.append(engine)
				rumblePlayers.append(player)
			} catch {
				LogStore.shared.append(level: 2, "Haptics unavailable: \(error)")
			}
		}
	}

	/// left = low frequency (left handle), right = high frequency (right handle), 0...255
	func rumble(left: UInt8, right: UInt8) {
		for (i, player) in rumblePlayers.enumerated() {
			let value = Float(i == 0 ? left : right) / 255
			do {
				if value <= 0 {
					try player.stop(atTime: CHHapticTimeImmediate)
				} else {
					try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)], atTime: CHHapticTimeImmediate)
					try player.start(atTime: CHHapticTimeImmediate)
				}
			} catch {
				// Haptics are best-effort
			}
		}
	}
}

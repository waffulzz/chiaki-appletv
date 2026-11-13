// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import UIKit
import AVKit
import CoreMedia
import GameController
import SwiftUI

/// Full-screen stream. GCEventViewController keeps controller input (including Menu)
/// away from UIKit so it all goes to the console.
final class StreamViewController: GCEventViewController {
	private let session: StreamSession
	private let input = ControllerInput()
	private let statusLabel = UILabel()
	private let onFinished: (String?) -> Void
	private var finished = false
	private var connected = false

	init(console: RegisteredConsole, address: String, settings: StreamSettings, onFinished: @escaping (String?) -> Void) {
		self.session = StreamSession(console: console, address: address, settings: settings)
		self.onFinished = onFinished
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	deinit {
		LogStore.shared.append(level: 16, "StreamViewController released")
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		requestMatchingDisplayMode()
	}

	/// Ask tvOS to switch the TV to the stream's frame rate and SDR, if the user turned on
	/// Settings › Video and Audio › Match Content. That skips 4K/HDR upscaling and tone mapping
	/// on the Apple TV, and the TV's often slower HDR picture modes.
	/// UIWindow.avDisplayManager comes from an AVKit category that is missing at runtime on some
	/// tvOS versions (calling it then throws "unrecognized selector"), so look it up defensively.
	private var displayManager: AVDisplayManager? {
		guard let window = view.window else { return nil }
		let selector = NSSelectorFromString("avDisplayManager")
		if window.responds(to: selector) {
			return window.avDisplayManager
		}
		if let scene = window.windowScene, scene.responds(to: selector) {
			return scene.value(forKey: "avDisplayManager") as? AVDisplayManager
		}
		return nil
	}

	private func requestMatchingDisplayMode() {
		guard let manager = displayManager else {
			LogStore.shared.append(level: 4, "Display: display mode switching is not available on this tvOS version")
			return
		}
		guard manager.isDisplayCriteriaMatchingEnabled else {
			LogStore.shared.append(level: 4, "Display: Match Content is off in tvOS settings, keeping the current output mode")
			return
		}
		var format: CMVideoFormatDescription?
		let size = session.videoSize
		CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
			codecType: session.isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
			width: Int32(size.width), height: Int32(size.height), extensions: nil, formatDescriptionOut: &format)
		guard let format else { return }
		manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(session.fps), formatDescription: format)
		LogStore.shared.append(level: 4, "Display: requested \(size.width)x\(size.height) SDR @ \(session.fps) Hz")
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		displayManager?.preferredDisplayCriteria = nil
		// Hand controller input back to UIKit, otherwise the menus stop responding after the stream
		controllerUserInteractionEnabled = true
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black
		controllerUserInteractionEnabled = false
		view.layer.addSublayer(session.video.displayLayer)

		statusLabel.text = "Connecting…"
		statusLabel.textColor = .white
		statusLabel.font = .preferredFont(forTextStyle: .title2)
		statusLabel.textAlignment = .center
		statusLabel.numberOfLines = 0
		statusLabel.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(statusLabel)
		NSLayoutConstraint.activate([
			statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
			statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
		])

		input.isPS5 = session.isPS5
		input.onStateChange = { [weak self] state in self?.session.setControllerState(state) }
		input.onQuitRequested = { [weak self] in self?.confirmQuit() }
		session.onRumble = { [weak self] l, r in self?.input.rumble(left: l, right: r) }
		session.onEvent = { [weak self] event in self?.handle(event) }

		NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
			name: UIApplication.didEnterBackgroundNotification, object: nil)

		if !session.start() {
			finish(error: "Could not start the session. See Logs for details.")
		}
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		session.video.displayLayer.frame = view.bounds
	}

	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		// Siri Remote Menu/Back button
		if presses.contains(where: { $0.type == .menu }) {
			confirmQuit()
			return
		}
		super.pressesBegan(presses, with: event)
	}

	@objc private func appDidEnterBackground() {
		// The stream's sockets do not survive suspension; end the session cleanly
		finish(error: nil)
	}

	private func handle(_ event: StreamSession.Event) {
		switch event {
		case .connected:
			connected = true
			statusLabel.text = "Connected. Waiting for video…"
			DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.statusLabel.isHidden = true }
		case .loginPINRequested(let incorrect):
			askForLoginPIN(incorrect: incorrect)
		case .quit(let error, let reason):
			finish(error: error ? reason : nil)
		case .keyboardOpen(let text):
			showKeyboard(text: text)
		case .keyboardRemoteClose:
			if let alert = keyboardAlert {
				keyboardAlert = nil
				alert.dismiss(animated: true)
				controllerUserInteractionEnabled = false
			}
		}
	}

	private weak var keyboardAlert: UIAlertController?

	/// The console asked for text: use tvOS's own keyboard (with iPhone keyboard support)
	/// instead of the console's on-screen one, then send the result back.
	private func showKeyboard(text: String) {
		guard !finished else { return }
		keyboardAlert?.dismiss(animated: false)
		controllerUserInteractionEnabled = true
		let alert = UIAlertController(title: "Enter Text", message: nil, preferredStyle: .alert)
		alert.addTextField { field in
			field.text = text
			field.autocapitalizationType = .sentences
		}
		alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self, weak alert] _ in
			self?.session.finishKeyboard(text: alert?.textFields?.first?.text ?? "")
			self?.controllerUserInteractionEnabled = false
		})
		alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
			self?.session.finishKeyboard(text: nil)
			self?.controllerUserInteractionEnabled = false
		})
		keyboardAlert = alert
		let present: () -> Void = { [weak self] in
			self?.present(alert, animated: true) {
				alert.textFields?.first?.becomeFirstResponder() // straight to the keyboard
			}
		}
		if let shown = presentedViewController, shown !== alert {
			shown.dismiss(animated: false, completion: present)
		} else {
			present()
		}
	}

	private func askForLoginPIN(incorrect: Bool) {
		let alert = UIAlertController(title: incorrect ? "Incorrect PIN" : "Login PIN",
			message: "Enter the console's Remote Play login PIN.", preferredStyle: .alert)
		alert.addTextField { $0.keyboardType = .numberPad }
		alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
			self?.session.setLoginPIN(alert?.textFields?.first?.text ?? "")
		})
		alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(error: nil) })
		present(alert, animated: true)
	}

	private func confirmQuit() {
		guard presentedViewController == nil, !finished else { return }
		controllerUserInteractionEnabled = true
		let alert = UIAlertController(title: "End Remote Play?", message: nil, preferredStyle: .actionSheet)
		alert.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in self?.finish(error: nil) })
		alert.addAction(UIAlertAction(title: "Disconnect and Put Console to Rest", style: .default) { [weak self] _ in
			self?.session.sleepConsole()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.finish(error: nil) }
		})
		alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel) { [weak self] _ in
			self?.controllerUserInteractionEnabled = false
		})
		present(alert, animated: true)
	}

	private func finish(error: String?) {
		guard !finished else { return }
		finished = true
		controllerUserInteractionEnabled = true
		if let error { LogStore.shared.append(level: 1, "Stream ended: \(error)") }
		statusLabel.isHidden = false
		statusLabel.text = "Disconnecting…"
		session.stop { [weak self] in
			self?.onFinished(error)
		}
	}
}

/// SwiftUI wrapper for StreamViewController.
struct StreamView: UIViewControllerRepresentable {
	let console: RegisteredConsole
	let address: String
	let settings: StreamSettings
	let onFinished: (String?) -> Void

	func makeUIViewController(context: Context) -> StreamViewController {
		StreamViewController(console: console, address: address, settings: settings, onFinished: onFinished)
	}

	func updateUIViewController(_ controller: StreamViewController, context: Context) {}
}

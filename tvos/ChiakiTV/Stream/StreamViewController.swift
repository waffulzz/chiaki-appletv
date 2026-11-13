// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import UIKit
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

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
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

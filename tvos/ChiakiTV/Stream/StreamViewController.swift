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
	private let overlay: LatencyOverlayView?
	private var overlayTimer: Timer?
	private let onFinished: (String?) -> Void
	private var finished = false
	private var connected = false

	init(console: RegisteredConsole, address: String, settings: StreamSettings, onFinished: @escaping (String?) -> Void) {
		self.session = StreamSession(console: console, address: address, settings: settings)
		self.overlay = settings.showLatencyOverlay ? LatencyOverlayView() : nil
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
	private func requestMatchingDisplayMode() {
		guard let manager = view.window?.avDisplayManager else { return }
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
		view.window?.avDisplayManager.preferredDisplayCriteria = nil
		// Hand controller input back to UIKit, otherwise the menus stop responding after the stream
		controllerUserInteractionEnabled = true
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black
		controllerUserInteractionEnabled = false
		if let metal = session.video.metal {
			view.layer.addSublayer(metal.layer)
		} else {
			view.layer.addSublayer(session.video.displayLayer)
		}
		if let overlay {
			overlay.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(overlay)
			NSLayoutConstraint.activate([
				overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 60),
				overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -60),
			])
			input.onLeftStick = { [weak overlay] x, y in overlay?.setStick(x: x, y: y) }
			overlayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
				guard let self else { return }
				self.overlay?.setStats(self.session.video.statsText)
			}
		}

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
		if let metal = session.video.metal {
			metal.layout(bounds: view.bounds, scale: view.window?.screen.scale ?? UIScreen.main.scale)
		} else {
			session.video.displayLayer.frame = view.bounds
		}
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
		overlayTimer?.invalidate()
		overlayTimer = nil
		controllerUserInteractionEnabled = true
		if let error { LogStore.shared.append(level: 1, "Stream ended: \(error)") }
		statusLabel.isHidden = false
		statusLabel.text = "Disconnecting…"
		session.stop { [weak self] in
			self?.onFinished(error)
		}
	}
}

/// Debug overlay: a dot that follows the left stick (drawn locally, so it shows the Apple TV/TV
/// part of the delay on its own) and the latest video stats.
final class LatencyOverlayView: UIView {
	private let box = UIView()
	private let dot = UIView()
	private let stats = UILabel()
	private let boxSize: CGFloat = 160

	init() {
		super.init(frame: .zero)
		backgroundColor = UIColor.black.withAlphaComponent(0.5)
		layer.cornerRadius = 16
		box.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
		box.layer.borderWidth = 2
		box.translatesAutoresizingMaskIntoConstraints = false
		dot.backgroundColor = .systemGreen
		dot.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
		dot.layer.cornerRadius = 12
		box.addSubview(dot)
		stats.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
		stats.textColor = .white
		stats.numberOfLines = 2
		stats.text = "Waiting for video…"
		stats.translatesAutoresizingMaskIntoConstraints = false
		addSubview(box)
		addSubview(stats)
		NSLayoutConstraint.activate([
			box.widthAnchor.constraint(equalToConstant: boxSize),
			box.heightAnchor.constraint(equalToConstant: boxSize),
			box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
			box.topAnchor.constraint(equalTo: topAnchor, constant: 16),
			box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
			stats.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 20),
			stats.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
			stats.centerYAnchor.constraint(equalTo: centerYAnchor),
			stats.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
		])
		setStick(x: 0, y: 0)
	}

	required init?(coder: NSCoder) { fatalError() }

	func setStick(x: Float, y: Float) {
		let r = boxSize / 2 - 12
		dot.center = CGPoint(x: boxSize / 2 + CGFloat(x) * r, y: boxSize / 2 - CGFloat(y) * r)
	}

	func setStats(_ text: String) {
		if !text.isEmpty { stats.text = text }
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

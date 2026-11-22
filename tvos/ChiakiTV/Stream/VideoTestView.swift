// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#if DEBUG
import SwiftUI
import UIKit

/// Debug-only: plays a raw Annex-B file through VideoRenderer, one access unit per frame,
/// to exercise the decode path without a console. Launch with
///   -ChiakiTestVideo /path/to/file.h264   (or .h265 / .hevc)
/// The file must contain access unit delimiters (x264/x265 "aud=1").
/// Optional: -ChiakiTestSmooth YES (frame pacing), -ChiakiTestJitter YES (30 fps with random late frames).
final class VideoTestViewController: UIViewController {
	private let renderer: VideoRenderer
	private let units: [Data]
	private var index = 0
	private var link: CADisplayLink?
	private var failures = 0
	private let jitter: Bool
	private var tickCount = 0
	private var holdTicks = 0

	init(path: String) {
		let hevc = path.hasSuffix(".h265") || path.hasSuffix(".hevc")
		let defaults = UserDefaults.standard
		jitter = defaults.bool(forKey: "ChiakiTestJitter")
		renderer = VideoRenderer(hevc: hevc, smooth: defaults.bool(forKey: "ChiakiTestSmooth"), fps: jitter ? 30 : 60)
		let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
		units = Self.splitAccessUnits(data, hevc: hevc)
		super.init(nibName: nil, bundle: nil)
		LogStore.shared.append(level: 4, "Video test: \(units.count) access units from \(path)")
	}

	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black
		view.layer.addSublayer(renderer.displayLayer)
		let link = CADisplayLink(target: self, selector: #selector(tick))
		link.preferredFramesPerSecond = 60
		link.add(to: .main, forMode: .common)
		self.link = link
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		renderer.displayLayer.frame = view.bounds
	}

	@objc private func tick() {
		guard !units.isEmpty else { return }
		if jitter {
			// 30 fps (every other 60 Hz tick); now and then a frame arrives 1-2 ticks late
			tickCount += 1
			if holdTicks > 0 { holdTicks -= 1; return }
			if tickCount % 2 == 1 { return }
			if Int.random(in: 0..<8) == 0 { holdTicks = Int.random(in: 1...2); return }
		}
		let unit = units[index % units.count]
		let ok = unit.withUnsafeBytes { raw in
			renderer.submit(raw.bindMemory(to: UInt8.self).baseAddress!, raw.count)
		}
		if !ok { failures += 1 }
		index += 1
		if index % 120 == 0 {
			LogStore.shared.append(level: 4, "Video test: submitted \(index), decoded \(renderer.framesDecoded), rejected \(failures)")
		}
	}

	static func splitAccessUnits(_ data: Data, hevc: Bool) -> [Data] {
		let bytes = [UInt8](data)
		var starts: [Int] = []
		var i = 0
		while i + 3 < bytes.count {
			if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
				let type = hevc ? (bytes[i + 3] >> 1) & 0x3f : bytes[i + 3] & 0x1f
				if type == (hevc ? 35 : 9) {
					starts.append(i > 0 && bytes[i - 1] == 0 ? i - 1 : i)
				}
				i += 3
			} else {
				i += 1
			}
		}
		var result: [Data] = []
		for (n, s) in starts.enumerated() {
			let e = n + 1 < starts.count ? starts[n + 1] : bytes.count
			result.append(Data(bytes[s..<e]))
		}
		return result
	}
}

struct VideoTestView: UIViewControllerRepresentable {
	let path: String
	func makeUIViewController(context: Context) -> VideoTestViewController { VideoTestViewController(path: path) }
	func updateUIViewController(_ controller: VideoTestViewController, context: Context) {}
}
#endif

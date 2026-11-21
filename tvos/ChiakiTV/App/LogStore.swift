// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import QuartzCore
import os
import ChiakiTVBridge

/// Collects chiaki-lib log lines (from any thread) for the in-app log viewer and the system log.
final class LogStore: ObservableObject {
	static let shared = LogStore()

	struct Line: Identifiable {
		let id: Int
		let level: UInt32
		let text: String
	}

	@Published private(set) var lines: [Line] = []

	private let logger = Logger(subsystem: "chiaki-ng-tv", category: "chiaki")
	private let lock = NSLock()
	private var pending: [Line] = []
	private var nextID = 0
	private var flushScheduled = false
	private let maxLines = 1000

	func install() {
		let cb: ChiakiTVLogCallback = { level, msg, _ in
			guard let msg else { return }
			LogStore.shared.append(level: UInt32(bitPattern: level), String(cString: msg))
		}
		// Debug level hexdumps every control heartbeat; keep it out of the log
		let mask = CHIAKITV_LOG_ERROR.rawValue | CHIAKITV_LOG_WARNING.rawValue | CHIAKITV_LOG_INFO.rawValue
		chiakitv_set_log_callback(cb, nil, mask)
	}

	func append(level: UInt32, _ text: String) {
		switch level {
		case CHIAKITV_LOG_ERROR.rawValue: logger.error("\(text, privacy: .public)")
		case CHIAKITV_LOG_WARNING.rawValue: logger.warning("\(text, privacy: .public)")
		default: logger.info("\(text, privacy: .public)")
		}
		// Visible with `xcrun devicectl device process launch --console`
		fputs(String(format: "[chiaki %.3f] ", CACurrentMediaTime()) + text + "\n", stderr)
		lock.lock()
		pending.append(Line(id: nextID, level: level, text: text))
		nextID += 1
		let schedule = !flushScheduled
		flushScheduled = true
		lock.unlock()
		if schedule {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.flush() }
		}
	}

	private func flush() {
		lock.lock()
		let batch = pending
		pending.removeAll()
		flushScheduled = false
		lock.unlock()
		lines.append(contentsOf: batch)
		if lines.count > maxLines {
			lines.removeFirst(lines.count - maxLines)
		}
	}
}

// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

struct LogView: View {
	@ObservedObject private var log = LogStore.shared

	var body: some View {
		ScrollViewReader { proxy in
			List(log.lines) { line in
				Text(line.text)
					.font(.system(size: 22, design: .monospaced))
					.foregroundStyle(color(line.level))
					.id(line.id)
					.focusable()
			}
			.onAppear { if let last = log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
		}
		.navigationTitle("Logs")
	}

	private func color(_ level: UInt32) -> Color {
		switch level {
		case 1: return .red
		case 2: return .orange
		case 16: return .secondary
		default: return .primary
		}
	}
}

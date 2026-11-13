// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI
import ChiakiTVBridge

@main
struct ChiakiTVApp: App {
	@StateObject private var consoles = ConsoleStore()
	@StateObject private var settings = StreamSettings()

	init() {
		LogStore.shared.install()
		if chiakitv_init() != 0 {
			LogStore.shared.append(level: CHIAKITV_LOG_ERROR.rawValue, "chiaki-lib failed to initialize")
		}
	}

	var body: some Scene {
		WindowGroup {
			#if DEBUG
			if let path = UserDefaults.standard.string(forKey: "ChiakiTestVideo") {
				VideoTestView(path: path).ignoresSafeArea()
			} else {
				mainView
			}
			#else
			mainView
			#endif
		}
	}

	private var mainView: some View {
		HostListView()
			.environmentObject(consoles)
			.environmentObject(settings)
	}
}

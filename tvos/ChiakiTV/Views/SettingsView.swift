// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

struct SettingsView: View {
	@EnvironmentObject private var settings: StreamSettings
	@EnvironmentObject private var consoles: ConsoleStore

	var body: some View {
		Form {
			Section("Video") {
				Picker("Resolution", selection: $settings.resolution) {
					ForEach(Resolution.allCases) { Text($0.label).tag($0) }
				}
				Picker("Frame Rate", selection: $settings.fps) {
					Text("30 fps").tag(30)
					Text("60 fps").tag(60)
				}
				Picker("Codec", selection: $settings.codec) {
					ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
				}
				Picker("Bitrate", selection: $settings.bitrate) {
					Text("Automatic (\(settings.resolution.defaultBitrate / 1000) Mbps)").tag(0)
					ForEach([5000, 10000, 15000, 20000, 30000, 40000, 50000], id: \.self) { Text("\($0 / 1000) Mbps").tag($0) }
				}
			}
			Section {
				Toggle("Metal Renderer", isOn: $settings.useMetalRenderer)
				Toggle("Latency Overlay", isOn: $settings.showLatencyOverlay)
			} header: {
				Text("Latency")
			} footer: {
				Text("The Metal renderer shows each frame as soon as it is decoded. The overlay draws a dot that follows your left stick locally, plus video stats: if the dot lags too, the delay is in the TV or Apple TV (try your TV's Game Mode), not the stream.")
			}
			Section("PSN") {
				TextField("Account-ID (base64)", text: $settings.psnAccountID)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
			}
			Section("Registered Consoles") {
				if consoles.registered.isEmpty {
					Text("None").foregroundStyle(.secondary)
				}
				ForEach(consoles.registered) { console in
					HStack {
						VStack(alignment: .leading) {
							Text(console.nickname)
							Text("\(console.isPS5 ? "PS5" : "PS4") · \(console.macHex)").font(.caption).foregroundStyle(.secondary)
						}
						Spacer()
						Button("Forget", role: .destructive) { consoles.remove(console) }
					}
				}
			}
			Section("Manually Added Addresses") {
				if consoles.manualAddresses.isEmpty {
					Text("None").foregroundStyle(.secondary)
				}
				ForEach(consoles.manualAddresses, id: \.self) { address in
					HStack {
						Text(address)
						Spacer()
						Button("Remove", role: .destructive) { consoles.removeManualAddress(address) }
					}
				}
			}
			Section("Controls") {
				Text("Options + Create/Share: PS button\nL1 + R1 + L3 + R3, or Siri Remote Back: end Remote Play")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		}
		.navigationTitle("Settings")
	}
}

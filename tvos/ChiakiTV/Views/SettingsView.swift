// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

struct SettingsView: View {
	@EnvironmentObject private var settings: StreamSettings
	@EnvironmentObject private var consoles: ConsoleStore

	var body: some View {
		Form {
			Section("Video") {
				OptionRow(title: "Resolution", selection: $settings.resolution,
					options: Resolution.allCases.map { ($0, $0.label) })
				OptionRow(title: "Frame Rate", selection: $settings.fps,
					options: [(30, "30 fps"), (60, "60 fps")])
				OptionRow(title: "Codec", selection: $settings.codec,
					options: VideoCodec.allCases.map { ($0, $0.label) })
				OptionRow(title: "Bitrate", selection: $settings.bitrate,
					options: [(0, "Automatic (\(settings.resolution.defaultBitrate / 1000) Mbps)")]
						+ [5000, 10000, 15000, 20000, 30000, 40000, 50000].map { ($0, "\($0 / 1000) Mbps") })
			}
			Section {
				Toggle("Smooth Playback", isOn: $settings.smoothPlayback)
			} footer: {
				Text("Shows frames at an even pace so a frame that arrives late doesn't cause a stutter. Adds about one frame of latency. For 30 fps games, keep Frame Rate at 60 fps: the console still sends only the game's 30 frames, but each one is picked up sooner.")
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
			Section {
				OptionRow(title: "Touchpad", selection: $settings.touchpadMode,
					options: TouchpadMode.allCases.map { ($0, $0.label) })
			} header: {
				Text("Touchpad")
			} footer: {
				Text("Over Remote Play, the PS5 treats touches on the touchpad as clicks in some games, for example GTA 6 opens its map. \"Clicks only\" sends just touchpad clicks. \"Clicks and swipes\" also sends swipes but ignores taps. \"All touches\" sends everything, for games that rely on touch.")
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

/// A setting row that opens a list of choices. Used instead of Picker, whose pushed
/// selection screen comes up blank on tvOS 27.
struct OptionRow<Value: Hashable>: View {
	let title: String
	@Binding var selection: Value
	let options: [(Value, String)]

	var body: some View {
		NavigationLink {
			OptionList(title: title, selection: $selection, options: options)
		} label: {
			HStack {
				Text(title)
				Spacer()
				Text(options.first { $0.0 == selection }?.1 ?? "").foregroundStyle(.secondary)
			}
		}
	}
}

private struct OptionList<Value: Hashable>: View {
	let title: String
	@Binding var selection: Value
	let options: [(Value, String)]
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		List {
			ForEach(options.indices, id: \.self) { i in
				Button {
					selection = options[i].0
					dismiss()
				} label: {
					HStack {
						Text(options[i].1)
						Spacer()
						if options[i].0 == selection { Image(systemName: "checkmark") }
					}
				}
			}
		}
		.navigationTitle(title)
	}
}

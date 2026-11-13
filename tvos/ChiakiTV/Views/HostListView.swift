// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

struct StreamTarget: Identifiable {
	let console: RegisteredConsole
	let address: String
	var id: String { console.id + address }
}

struct RegisterTarget: Identifiable {
	let name: String
	let address: String
	let target: Int32
	var id: String { address }
}

struct HostListView: View {
	@EnvironmentObject private var consoles: ConsoleStore
	@EnvironmentObject private var settings: StreamSettings
	@Environment(\.scenePhase) private var scenePhase
	@State private var streamTarget: StreamTarget?
	@State private var registerTarget: RegisterTarget?
	@State private var showAddHost = false
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack {
			List {
				Section {
					if consoles.entries.isEmpty {
						VStack(alignment: .leading, spacing: 8) {
							Text("Searching for consoles…")
							Text("Make sure your PS5 or PS4 is on the same network with Remote Play enabled. You can also add it by IP address.")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						.padding(.vertical)
					}
					ForEach(consoles.entries) { entry in
						ConsoleRow(entry: entry, onConnect: connect, onRegister: register, onWake: wake, onForget: forget)
					}
				} header: {
					Text("Consoles")
				} footer: {
					if consoles.discoveryFailed {
						Text("Local network discovery could not start. Add your console by IP address instead.")
					}
				}

				Section {
					Button { showAddHost = true } label: { Label("Add Console by IP Address", systemImage: "plus") }
					NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
					NavigationLink { LogView() } label: { Label("Logs", systemImage: "doc.plaintext") }
				}
			}
			.navigationTitle("chiaki-ng")
		}
		.onAppear { consoles.startDiscovery() }
		.onChange(of: scenePhase) { _, phase in
			// tvOS tears down sockets of suspended apps; restart discovery on return
			switch phase {
			case .background: consoles.stopDiscovery()
			case .active: if streamTarget == nil { consoles.startDiscovery() }
			default: break
			}
		}
		.sheet(item: $registerTarget) { target in
			RegisterView(target: target) { console in
				consoles.add(console)
				registerTarget = nil
			}
		}
		.sheet(isPresented: $showAddHost) {
			AddHostView { address in
				consoles.addManualAddress(address)
				showAddHost = false
			}
		}
		.fullScreenCover(item: $streamTarget) { target in
			StreamView(console: target.console, address: target.address, settings: settings) { error in
				streamTarget = nil
				consoles.startDiscovery()
				if let error {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { errorMessage = error }
				}
			}
			.ignoresSafeArea()
		}
		.alert("Remote Play Ended", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(errorMessage ?? "")
		}
	}

	private func connect(_ console: RegisteredConsole, _ address: String) {
		// Discovery shares the console's UDP ports' attention; pause it while streaming
		consoles.stopDiscovery()
		streamTarget = StreamTarget(console: console, address: address)
	}

	private func register(_ entry: ConsoleEntry) {
		guard let address = entry.address else { return }
		// Without discovery info, assume a PS5 (CHIAKI_TARGET_PS5_1)
		let target = entry.discovered?.target ?? 1_000_100
		registerTarget = RegisterTarget(name: entry.name, address: address, target: target)
	}

	private func wake(_ console: RegisteredConsole, _ address: String) {
		consoles.wake(console, address: address)
	}

	private func forget(_ entry: ConsoleEntry) {
		if let registered = entry.registered { consoles.remove(registered) }
		if let manual = entry.manualAddress { consoles.removeManualAddress(manual) }
	}
}

private struct ConsoleRow: View {
	let entry: ConsoleEntry
	let onConnect: (RegisteredConsole, String) -> Void
	let onRegister: (ConsoleEntry) -> Void
	let onWake: (RegisteredConsole, String) -> Void
	var onForget: ((ConsoleEntry) -> Void)?

	var body: some View {
		// One button per row: tvOS lists focus whole rows, so secondary actions live in the context menu
		Button(action: primaryAction) {
			HStack(spacing: 32) {
				Image(systemName: "gamecontroller.fill")
					.font(.system(size: 56))
					.foregroundStyle(stateColor)
					.frame(width: 80)
				VStack(alignment: .leading, spacing: 6) {
					Text(entry.name).font(.headline)
					HStack(spacing: 16) {
						Text(entry.isPS5 ? "PS5" : "PS4")
						Text(stateText).foregroundStyle(stateColor)
						if let address = entry.address { Text(address) }
					}
					.font(.caption)
					.opacity(0.7)
					if let app = entry.discovered?.runningApp, !app.isEmpty {
						Text(app).font(.caption2).opacity(0.7)
					}
				}
				Spacer()
				Text(primaryLabel).font(.headline)
			}
			.padding(.vertical, 8)
		}
		.disabled(entry.address == nil)
		.contextMenu {
			if let registered = entry.registered, let address = entry.address {
				Button("Play") { onConnect(registered, address) }
				Button("Wake") { onWake(registered, address) }
			}
			if entry.address != nil {
				Button(entry.registered == nil ? "Register" : "Register Again") { onRegister(entry) }
			}
			if let onForget {
				Button(entry.registered != nil ? "Forget Console" : "Remove", role: .destructive) { onForget(entry) }
			}
		}
	}

	private var primaryLabel: String {
		guard entry.address != nil else { return "" }
		guard entry.registered != nil else { return "Register" }
		return entry.discovered?.state == .standby ? "Wake" : "Play"
	}

	private func primaryAction() {
		guard let address = entry.address else { return }
		guard let registered = entry.registered else {
			onRegister(entry)
			return
		}
		if entry.discovered?.state == .standby {
			onWake(registered, address)
		} else {
			onConnect(registered, address)
		}
	}

	private var stateText: String {
		guard let d = entry.discovered else { return entry.registered != nil ? "Not found" : "Unknown" }
		switch d.state {
		case .ready: return "Ready"
		case .standby: return "Rest Mode"
		case .unknown: return "Unknown"
		}
	}

	private var stateColor: AnyShapeStyle {
		switch entry.discovered?.state {
		case .ready: return AnyShapeStyle(Color.blue)
		case .standby: return AnyShapeStyle(Color.orange)
		default: return AnyShapeStyle(.secondary)
		}
	}
}

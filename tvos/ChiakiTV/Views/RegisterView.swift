// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

struct RegisterView: View {
	let target: RegisterTarget
	let onRegistered: (RegisteredConsole) -> Void

	@EnvironmentObject private var settings: StreamSettings
	@Environment(\.dismiss) private var dismiss
	@StateObject private var registration = Registration()
	@State private var accountID = ""
	@State private var pin = ""

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Text("On the console, open Settings › System › Remote Play › Pair Device (PS5) or Settings › Remote Play Connection Settings › Add Device (PS4), then enter the 8-digit code below.")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				Section("PSN Account-ID (base64)") {
					TextField("e.g. AbCdEfGhIjk=", text: $accountID)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}
				Section("PIN") {
					TextField("8-digit code", text: $pin)
						.keyboardType(.numberPad)
				}
				Section {
					Button(registration.status == .running ? "Registering…" : "Register") {
						settings.psnAccountID = accountID
						registration.start(address: target.address, target: target.target, accountIDBase64: accountID, pin: pin)
					}
					.disabled(registration.status == .running)
					Button("Cancel", role: .cancel) { dismiss() }
				} footer: {
					statusText
				}
			}
			.navigationTitle("Register \(target.name)")
		}
		.onAppear { accountID = settings.psnAccountID }
		.onChange(of: registration.status) { _, status in
			if case .success(let console) = status {
				onRegistered(console)
			}
		}
	}

	@ViewBuilder private var statusText: some View {
		switch registration.status {
		case .failed(let message): Text(message).foregroundStyle(.red)
		case .success: Text("Registered!").foregroundStyle(.green)
		case .running: Text("Talking to \(target.address)…")
		case .idle: Text("Your Account-ID can be looked up with chiaki-ng on a computer (Settings › PSN) or any PSN Account-ID tool.")
		}
	}
}

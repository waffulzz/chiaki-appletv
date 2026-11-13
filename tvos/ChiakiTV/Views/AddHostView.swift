// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import SwiftUI

struct AddHostView: View {
	let onAdd: (String) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var address = ""

	var body: some View {
		NavigationStack {
			Form {
				Section("IP address or hostname") {
					TextField("192.168.1.20", text: $address)
						.keyboardType(.numbersAndPunctuation)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}
				Section {
					Button("Add") { onAdd(address) }
						.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
					Button("Cancel", role: .cancel) { dismiss() }
				}
			}
			.navigationTitle("Add Console")
		}
	}
}

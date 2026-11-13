// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import ChiakiTVBridge

/// Runs one registration attempt against a console (Settings > System > Remote Play > Pair Device on the console).
final class Registration: ObservableObject {
	enum Status: Equatable {
		case idle, running, success(RegisteredConsole), failed(String)
	}

	@Published private(set) var status: Status = .idle
	private var handle: OpaquePointer?
	private var context: Unmanaged<Context>?
	private var address = ""

	/// Handed to the C callback; holds the Registration weakly so it can go away while the regist thread finishes.
	private final class Context {
		weak var registration: Registration?
		let address: String
		init(_ registration: Registration, address: String) { self.registration = registration; self.address = address }
	}

	deinit {
		release()
	}

	private func release() {
		guard let h = handle, let ctx = context else { return }
		handle = nil
		context = nil
		DispatchQueue.global().async {
			chiakitv_regist_free(h) // joins the regist thread, so no callback runs after this
			ctx.release()
		}
	}

	/// target: from discovery (ChiakiTarget). PS5 consoles are fine with CHIAKI_TARGET_PS5_1.
	func start(address: String, target: Int32, accountIDBase64: String, pin: String, broadcast: Bool = false) {
		guard status != .running else { return }
		guard let accountID = Data(base64Encoded: accountIDBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
		      accountID.count == 8 else {
			status = .failed("The PSN Account-ID must be 8 bytes encoded as base64 (12 characters, usually ending in \"=\").")
			return
		}
		let pinDigits = pin.trimmingCharacters(in: .whitespacesAndNewlines)
		guard pinDigits.count == 8, let pinValue = UInt32(pinDigits) else {
			status = .failed("The PIN must be the 8 digits shown on the console.")
			return
		}
		release()
		self.address = address
		status = .running

		let cb: ChiakiTVRegistCallback = { result, hostPtr, user in
			guard let user else { return }
			let ctx = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
			var console: RegisteredConsole?
			if result == Int32(CHIAKITV_REGIST_SUCCESS.rawValue), let h = hostPtr?.pointee {
				console = RegisteredConsole(
					macHex: bytesFromCTuple(h.server_mac).hexString,
					nickname: stringFromCTuple(h.server_nickname),
					target: h.target,
					registKey: bytesFromCTuple(h.rp_regist_key),
					rpKey: bytesFromCTuple(h.rp_key),
					lastAddress: ctx.address)
			}
			DispatchQueue.main.async {
				guard let reg = ctx.registration else { return }
				switch result {
				case Int32(CHIAKITV_REGIST_SUCCESS.rawValue):
					if let console { reg.status = .success(console) }
				case Int32(CHIAKITV_REGIST_CANCELED.rawValue):
					reg.status = .idle
				default:
					reg.status = .failed("Registration failed. Check the PIN and Account-ID, and see Logs for details.")
				}
			}
		}

		var account = [UInt8](accountID)
		let ctx = Unmanaged.passRetained(Context(self, address: address))
		handle = address.withCString { host in
			chiakitv_regist_start(host, target, &account, pinValue, broadcast, cb, ctx.toOpaque())
		}
		if handle == nil {
			ctx.release()
			status = .failed("Could not start registration. See Logs for details.")
		} else {
			context = ctx
		}
	}
}

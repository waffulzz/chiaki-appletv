// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import ChiakiTVBridge

/// Credentials obtained by registering with a console. Persisted.
struct RegisteredConsole: Codable, Identifiable, Hashable {
	var macHex: String
	var nickname: String
	var target: Int32
	var registKey: [UInt8] // rp_regist_key, 16 bytes
	var rpKey: [UInt8] // rp_key ("morning"), 16 bytes
	var lastAddress: String?

	var id: String { macHex }
	var isPS5: Bool { target >= 1_000_000 }
}

/// A console seen by discovery.
struct DiscoveredConsole: Identifiable, Hashable {
	enum State: Int32 { case unknown = 0, ready = 1, standby = 2 }

	var hostID: String // MAC hex
	var name: String
	var address: String
	var state: State
	var isPS5: Bool
	var target: Int32
	var systemVersion: String
	var runningApp: String

	var id: String { hostID.uppercased() }
}

/// One row in the console list: discovered, registered, or both.
struct ConsoleEntry: Identifiable {
	var id: String
	var discovered: DiscoveredConsole?
	var registered: RegisteredConsole?
	var manualAddress: String?

	var name: String { discovered?.name ?? registered?.nickname ?? manualAddress ?? "Console" }
	var address: String? { discovered?.address ?? manualAddress ?? registered?.lastAddress }
	var isPS5: Bool { discovered?.isPS5 ?? registered?.isPS5 ?? true }
}

/// Owns discovery and the persisted list of registered consoles and manually added addresses.
final class ConsoleStore: ObservableObject {
	@Published private(set) var registered: [RegisteredConsole] = []
	@Published private(set) var manualAddresses: [String] = []
	@Published private(set) var discovered: [String: DiscoveredConsole] = [:]
	@Published private(set) var discoveryFailed = false

	private let defaults = UserDefaults.standard
	private var discoveries: [String: OpaquePointer] = [:] // key "" = broadcast
	private var discoveredBySource: [String: [DiscoveredConsole]] = [:]

	init() {
		if let data = defaults.data(forKey: "registeredConsoles"),
		   let list = try? JSONDecoder().decode([RegisteredConsole].self, from: data) {
			registered = list
		}
		manualAddresses = defaults.stringArray(forKey: "manualAddresses") ?? []
	}

	deinit {
		stopDiscovery()
	}

	// MARK: - Entries

	var entries: [ConsoleEntry] {
		var result: [ConsoleEntry] = []
		var seen = Set<String>()
		for d in discovered.values.sorted(by: { $0.name < $1.name }) {
			result.append(ConsoleEntry(id: d.id, discovered: d, registered: registered(forMAC: d.hostID)))
			seen.insert(d.id)
		}
		for r in registered where !seen.contains(r.macHex.uppercased()) {
			result.append(ConsoleEntry(id: r.macHex.uppercased(), registered: r))
			seen.insert(r.macHex.uppercased())
		}
		let knownAddresses = Set(result.compactMap { $0.address })
		for a in manualAddresses where !knownAddresses.contains(a) {
			result.append(ConsoleEntry(id: "manual-\(a)", manualAddress: a))
		}
		return result
	}

	func registered(forMAC mac: String) -> RegisteredConsole? {
		registered.first { $0.macHex.caseInsensitiveCompare(mac) == .orderedSame }
	}

	// MARK: - Persistence

	func add(_ console: RegisteredConsole) {
		registered.removeAll { $0.macHex.caseInsensitiveCompare(console.macHex) == .orderedSame }
		registered.append(console)
		saveRegistered()
	}

	func remove(_ console: RegisteredConsole) {
		registered.removeAll { $0.macHex == console.macHex }
		saveRegistered()
	}

	func updateLastAddress(_ address: String, for macHex: String) {
		guard let i = registered.firstIndex(where: { $0.macHex.caseInsensitiveCompare(macHex) == .orderedSame }),
		      registered[i].lastAddress != address else { return }
		registered[i].lastAddress = address
		saveRegistered()
	}

	func addManualAddress(_ address: String) {
		let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !a.isEmpty, !manualAddresses.contains(a) else { return }
		manualAddresses.append(a)
		defaults.set(manualAddresses, forKey: "manualAddresses")
		if !discoveries.isEmpty { startDiscovery(source: a) }
	}

	func removeManualAddress(_ address: String) {
		manualAddresses.removeAll { $0 == address }
		defaults.set(manualAddresses, forKey: "manualAddresses")
		if let d = discoveries.removeValue(forKey: address) { chiakitv_discovery_stop(d) }
		discoveredBySource[address] = nil
		rebuildDiscovered()
	}

	private func saveRegistered() {
		if let data = try? JSONEncoder().encode(registered) {
			defaults.set(data, forKey: "registeredConsoles")
		}
	}

	// MARK: - Discovery

	func startDiscovery() {
		guard discoveries.isEmpty else { return }
		startDiscovery(source: "")
		for a in manualAddresses { startDiscovery(source: a) }
		// Registered consoles that we know an address for are asked directly too, in case broadcast is blocked
		for r in registered {
			if let a = r.lastAddress, !manualAddresses.contains(a) { startDiscovery(source: a) }
		}
	}

	func stopDiscovery() {
		for d in discoveries.values { chiakitv_discovery_stop(d) }
		discoveries.removeAll()
	}

	private final class SourceContext {
		weak var store: ConsoleStore?
		let source: String
		init(store: ConsoleStore, source: String) { self.store = store; self.source = source }
	}

	private var contexts: [String: SourceContext] = [:]

	private func startDiscovery(source: String) {
		guard discoveries[source] == nil else { return }
		let ctx = SourceContext(store: self, source: source)
		contexts[source] = ctx
		let cb: ChiakiTVDiscoveryCallback = { hostsPtr, count, user in
			guard let user else { return }
			let ctx = Unmanaged<SourceContext>.fromOpaque(user).takeUnretainedValue()
			var list: [DiscoveredConsole] = []
			if let hostsPtr {
				for h in UnsafeBufferPointer(start: hostsPtr, count: count) {
					list.append(DiscoveredConsole(
						hostID: stringFromCTuple(h.host_id),
						name: stringFromCTuple(h.host_name),
						address: stringFromCTuple(h.host_addr),
						state: DiscoveredConsole.State(rawValue: h.state) ?? .unknown,
						isPS5: h.ps5,
						target: h.target,
						systemVersion: stringFromCTuple(h.system_version),
						runningApp: stringFromCTuple(h.running_app_name)))
				}
			}
			let source = ctx.source
			DispatchQueue.main.async {
				ctx.store?.discoveredBySource[source] = list
				ctx.store?.rebuildDiscovered()
			}
		}
		let user = Unmanaged.passUnretained(ctx).toOpaque()
		let handle: OpaquePointer? = source.isEmpty
			? chiakitv_discovery_start(nil, cb, user)
			: source.withCString { chiakitv_discovery_start($0, cb, user) }
		if let handle {
			discoveries[source] = handle
		} else if source.isEmpty {
			discoveryFailed = true
		}
	}

	private func rebuildDiscovered() {
		var merged: [String: DiscoveredConsole] = [:]
		for list in discoveredBySource.values {
			for d in list where !d.hostID.isEmpty {
				merged[d.id] = d
			}
		}
		discovered = merged
		for d in merged.values {
			updateLastAddress(d.address, for: d.hostID)
		}
	}

	// MARK: - Wakeup

	func wake(_ console: RegisteredConsole, address: String) {
		var key = console.registKey
		let ps5 = console.isPS5
		DispatchQueue.global().async {
			let r = address.withCString { host in
				key.withUnsafeMutableBufferPointer { buf in
					buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
						chiakitv_wakeup(host, $0, buf.count, ps5)
					}
				}
			}
			LogStore.shared.append(level: CHIAKITV_LOG_INFO.rawValue, "Wakeup sent to \(address): \(r == 0 ? "ok" : "error \(r)")")
		}
	}
}

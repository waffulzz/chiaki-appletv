// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation

/// Reads a fixed-size C char array (imported by Swift as a tuple) as a String.
func stringFromCTuple<T>(_ tuple: T) -> String {
	withUnsafeBytes(of: tuple) { raw in
		let bytes = raw.bindMemory(to: UInt8.self)
		let end = bytes.firstIndex(of: 0) ?? bytes.count
		return String(decoding: bytes[..<end], as: UTF8.self)
	}
}

/// Reads a fixed-size C byte array (imported by Swift as a tuple) as [UInt8].
func bytesFromCTuple<T>(_ tuple: T) -> [UInt8] {
	withUnsafeBytes(of: tuple) { Array($0) }
}

/// Copies bytes into a fixed-size C array, zero-padding the rest.
func copyBytes<T>(_ bytes: [UInt8], into tuple: inout T) {
	withUnsafeMutableBytes(of: &tuple) { raw in
		raw.initializeMemory(as: UInt8.self, repeating: 0)
		raw.copyBytes(from: bytes.prefix(raw.count))
	}
}

extension Array where Element == UInt8 {
	var hexString: String { map { String(format: "%02X", $0) }.joined() }
}

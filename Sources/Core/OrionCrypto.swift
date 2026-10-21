import Foundation
import CryptoKit

public final class OrionCrypto {
    public static let shared = OrionCrypto()
    
    private struct KeyMaterial {
        let key: [UInt8]
        let sbox: [UInt8]
        let rsbox: [UInt8]
    }
    
    private var keys: [KeyMaterial] = []
    
    public init(secret: String = "OrionNexus2025CryptoKey!Secure") {
        for n in 0..<5 {
            let salt = "_orion_key_\(n)_v2_\(secret)"
            let digest = SHA256.hash(data: Data(salt.utf8))
            let keyBytes = Array(digest)
            
            var sbox = Array(UInt8(0)...UInt8(255))
            var j: Int = 0
            for i in 0..<256 {
                j = (j + Int(sbox[i]) + Int(keyBytes[i % keyBytes.count])) % 256
                sbox.swapAt(i, j)
            }
            
            var rsbox = [UInt8](repeating: 0, count: 256)
            for i in 0..<256 {
                rsbox[Int(sbox[i])] = UInt8(i)
            }
            keys.append(KeyMaterial(key: keyBytes, sbox: sbox, rsbox: rsbox))
        }
    }
    
    @inline(__always)
    private func rotateRight(_ val: UInt8, _ shift: Int) -> UInt8 {
        let s = shift % 8
        return (val >> s) | (val << (8 - s))
    }
    
    public func decryptEnvelope(json: [String: Any]) throws -> Data {
        guard let b64 = json["d"] as? String else {
            throw URLError(.cannotDecodeContentData)
        }
        let v = json["v"] as? Int ?? 1
        let k = json["k"] as? Int ?? 0
        let keyIndex = (v == 1) ? 0 : k
        
        guard keyIndex >= 0 && keyIndex < keys.count,
              let raw = Data(base64Encoded: b64) else {
            throw URLError(.cannotDecodeRawData)
        }
        
        let kInfo = keys[keyIndex]
        let key = kInfo.key
        let rsbox = kInfo.rsbox
        let keyLen = key.count
        let count = raw.count
        let rawBytes = Array(raw)
        var output = [UInt8](repeating: 0, count: count)
        
        for c in stride(from: count - 1, through: 0, by: -1) {
            var val = rawBytes[c]
            val ^= (c > 0) ? rawBytes[c - 1] : key[keyLen - 1]
            val = rsbox[Int(val)]
            let shift = ((Int(key[(c + 3) % keyLen]) + (c & 0xFF)) & 0xFF) % 7 + 1
            val = rotateRight(val, shift)
            val ^= key[c % keyLen]
            output[c] = val
        }
        
        return Data(output)
    }
}

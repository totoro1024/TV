import Foundation

/// 按原插件的LZ-String Base64格式解码，限制输入、字典及输出大小。
enum LZStringResponse {
    static func decode(_ text:String) throws -> Data {
        let raw = text.filter { !$0.isWhitespace }
        guard !raw.isEmpty,raw.utf8.count <= 1024*1024 else { throw TVError.message("压缩响应长度无效") }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)
        let lookup = Dictionary(uniqueKeysWithValues:alphabet.enumerated().map { ($0.element,$0.offset) })
        var values:[Int] = []
        for byte in raw.utf8 {
            guard let value = lookup[byte] else { throw TVError.message("压缩响应包含无效字符") }
            values.append(value)
        }
        var cursor = 0, mask = 32
        func bits(_ count:Int) throws -> Int {
            var result = 0
            for shift in 0..<count {
                guard cursor < values.count else { throw TVError.message("压缩响应被截断") }
                if values[cursor] & mask != 0 { result |= 1 << shift }
                mask >>= 1
                if mask == 0 { mask = 32;cursor += 1 }
            }
            return result
        }
        var dictionary:[[UInt16]] = [[],[],[]], dictionaryUnits = 0
        func append(_ word:[UInt16]) throws {
            guard dictionary.count < 65536,dictionaryUnits + word.count <= 4*1024*1024 else { throw TVError.message("压缩响应字典超过限制") }
            dictionary.append(word);dictionaryUnits += word.count
        }
        let first:UInt16
        switch try bits(2) {
        case 0:first = UInt16(try bits(8))
        case 1:first = UInt16(try bits(16))
        case 2:return Data()
        default:throw TVError.message("压缩响应头无效")
        }
        var previous = [first],result = [first],width = 3,remaining = 4
        try append(previous)
        while true {
            var code = try bits(width)
            if code == 2 { return Data(String(decoding:result,as:UTF16.self).utf8) }
            if code == 0 || code == 1 {
                try append([UInt16(try bits(code == 0 ? 8 : 16))])
                code = dictionary.count-1;remaining -= 1
            }
            if remaining == 0 { remaining = 1 << width;width += 1 }
            let word:[UInt16]
            if code < dictionary.count,!dictionary[code].isEmpty { word = dictionary[code] }
            else if code == dictionary.count { word = previous + [previous[0]] }
            else { throw TVError.message("压缩响应字典索引无效") }
            guard result.count + word.count <= 2*1024*1024 else { throw TVError.message("压缩响应展开超过限制") }
            result += word
            try append(previous + [word[0]])
            remaining -= 1;previous = word
            if remaining == 0 { remaining = 1 << width;width += 1 }
        }
    }
}

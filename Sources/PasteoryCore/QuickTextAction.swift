import CryptoKit
import Foundation

public enum QuickTextAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case base64Encode, base64Decode, md5, rgbaToHex, hexToRGBA, urlEncode, urlDecode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .base64Encode: L10n.tr("Base64 编码")
        case .base64Decode: L10n.tr("Base64 解码")
        case .md5: "MD5"
        case .rgbaToHex: "RGBA → HEX"
        case .hexToRGBA: "HEX → RGBA"
        case .urlEncode: L10n.tr("URL 编码")
        case .urlDecode: L10n.tr("URL 解码")
        }
    }

    public var guidance: String {
        switch self {
        case .base64Encode: L10n.tr("按 UTF-8 编码，保留空格和换行。")
        case .base64Decode: L10n.tr("支持标准 Base64 和 Base64URL；解码结果必须是 UTF-8 文本。")
        case .md5: L10n.tr("计算 UTF-8 文本的 32 位小写 MD5。MD5 不适合密码或安全校验。")
        case .rgbaToHex: L10n.tr("例如 rgba(255, 128, 0, 0.5)；输出 #RRGGBBAA，透明度在末尾。")
        case .hexToRGBA: L10n.tr("支持 #RGB、#RGBA、#RRGGBB、#RRGGBBAA；透明度在末尾。")
        case .urlEncode: L10n.tr("编码 URL 参数值，空格转为 %20；不会保留 /、?、& 等分隔符。")
        case .urlDecode: L10n.tr("解码百分号转义；保留 +，不按表单格式把它当作空格。")
        }
    }

    public var resultDescription: String {
        switch self {
        case .base64Encode: L10n.tr("Base64 编码后")
        case .base64Decode: L10n.tr("Base64 解码后")
        case .md5: L10n.tr("计算 MD5 后")
        case .rgbaToHex: L10n.tr("RGBA 转为 HEX 后")
        case .hexToRGBA: L10n.tr("HEX 转为 RGBA 后")
        case .urlEncode: L10n.tr("URL 编码后")
        case .urlDecode: L10n.tr("URL 解码后")
        }
    }

    public func makeResultClip(input: String, sourceClip: Clip?, source: ClipSource) throws -> Clip {
        let output = try apply(to: input)
        let data = Data(output.utf8)
        let now = Date()
        var clip = ClipClassifier.makeClip(from: PasteboardCapture(
            items: [CapturedItem(order: 0, representations: [
                CapturedRepresentation(uti: "public.utf8-plain-text", data: data)
            ])],
            source: source,
            capturedAt: now
        )) ?? Clip(
            createdAt: now, updatedAt: now, lastCopiedAt: now,
            primaryKind: .text, source: source, previewText: output,
            contentHash: UUID().uuidString, byteSize: data.count,
            items: [ClipItem(order: 0, representations: [
                ClipRepresentation(uti: "public.utf8-plain-text", storage: .inline(data))
            ])]
        )
        let transformation = QuickTextTransformation(
            action: self, originalText: input,
            sourceClipID: sourceClip?.id, source: sourceClip?.source
        )
        clip.note = transformation.note
        clip.quickTextTransformations = [transformation]
        clip.identityKey = try ClipIdentity.key(for: clip)
        return clip
    }

    public func apply(to input: String) throws -> String {
        switch self {
        case .base64Encode:
            return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            var encoded = input.components(separatedBy: .whitespacesAndNewlines).joined()
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
            let body = encoded.prefix { $0 != "=" }
            let padding = encoded.dropFirst(body.count)
            guard body.unicodeScalars.allSatisfy(alphabet.contains),
                  padding.allSatisfy({ $0 == "=" }), padding.count <= 2,
                  body.count % 4 != 1,
                  padding.isEmpty || encoded.count % 4 == 0 else {
                throw QuickTextActionError.invalidBase64
            }
            if padding.isEmpty { encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4) }
            guard let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded else {
                throw QuickTextActionError.invalidBase64
            }
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw QuickTextActionError.nonUTF8
            }
            return decoded
        case .md5:
            return Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        case .urlEncode:
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let encoded = input.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw QuickTextActionError.invalidURL
            }
            return encoded
        case .urlDecode:
            guard let decoded = input.removingPercentEncoding else { throw QuickTextActionError.invalidURL }
            return decoded
        case .rgbaToHex:
            let pattern = #"^\s*(rgb|rgba)\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*(?:,\s*([0-9]*\.?[0-9]+)\s*)?\)\s*$"#
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            guard let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else {
                throw QuickTextActionError.invalidColor
            }
            func component(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: input) else { return nil }
                return String(input[range])
            }
            guard let red = component(2).flatMap(Int.init),
                  let green = component(3).flatMap(Int.init),
                  let blue = component(4).flatMap(Int.init),
                  [red, green, blue].allSatisfy({ (0...255).contains($0) }),
                  (component(1)?.lowercased() == "rgba") == (component(5) != nil) else {
                throw QuickTextActionError.invalidColor
            }
            let alpha = component(5).flatMap(Double.init) ?? 1
            guard alpha.isFinite, (0...1).contains(alpha) else { throw QuickTextActionError.invalidColor }
            return String(format: "#%02X%02X%02X%02X", red, green, blue, Int((alpha * 255).rounded()))
        case .hexToRGBA:
            var hex = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard [3, 4, 6, 8].contains(hex.count),
                  hex.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains) else {
                throw QuickTextActionError.invalidColor
            }
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { hex += "FF" }
            guard let value = UInt32(hex, radix: 16) else { throw QuickTextActionError.invalidColor }
            let red = (value >> 24) & 255, green = (value >> 16) & 255, blue = (value >> 8) & 255
            let alpha = (Double(value & 255) / 255 * 1_000_000).rounded() / 1_000_000
            let alphaText = alpha == 0 ? "0" : alpha == 1 ? "1" : String(alpha)
            return "rgba(\(red), \(green), \(blue), \(alphaText))"
        }
    }
}

public struct QuickTextTransformation: Codable, Hashable, Sendable {
    public var action: QuickTextAction
    public var originalText: String
    public var sourceClipID: UUID?
    public var source: ClipSource?

    public init(action: QuickTextAction, originalText: String, sourceClipID: UUID? = nil, source: ClipSource? = nil) {
        self.action = action
        self.originalText = originalText
        self.sourceClipID = sourceClipID
        self.source = source
    }

    public var note: String {
        L10n.tr("\(originalText)（\(action.resultDescription)）\n来源：\(source?.appName ?? L10n.tr("手动输入"))")
    }
}

public enum QuickTextActionError: LocalizedError {
    case invalidBase64, nonUTF8, invalidURL, invalidColor, noText

    public var errorDescription: String? {
        switch self {
        case .invalidBase64: L10n.tr("不是有效的 Base64 文本，请检查字符和填充符。")
        case .nonUTF8: L10n.tr("解码结果不是 UTF-8 文本，无法在文本工具中显示。")
        case .invalidURL: L10n.tr("URL 转义无效，请检查 % 后的十六进制字符和 UTF-8 编码。")
        case .invalidColor: L10n.tr("颜色格式无效：RGB 分量需在 0–255，透明度需在 0–1。")
        case .noText: L10n.tr("这条内容没有可用的文本，请手动输入。")
        }
    }
}

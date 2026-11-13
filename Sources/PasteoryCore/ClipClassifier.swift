import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum ClipClassifier {
    private static let maximumClassificationCharacters = 64 * 1024
    private static let maximumClassificationLines = 600
    private static let colorPattern = try! NSRegularExpression(
        pattern: #"(?i)^(?:#[0-9a-f]{3,8}|rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}(?:\s*,\s*(?:0|1|0?\.\d+))?\s*\)|hsla?\(\s*[-+]?\d+(?:\.\d+)?(?:deg)?\s*,\s*\d+(?:\.\d+)?%\s*,\s*\d+(?:\.\d+)?%(?:\s*,\s*(?:0|1|0?\.\d+))?\s*\))$"#
    )

    public static func makeClip(from capture: PasteboardCapture) -> Clip? {
        guard !capture.items.isEmpty else { return nil }
        var kinds = Set<ClipKind>()
        var convertedItems: [ClipItem] = []
        var previewCandidates: [String] = []
        var codeCandidates: [CodeMetadata] = []
        var totalBytes = 0
        var hasher = SHA256()

        for capturedItem in capture.items.sorted(by: { $0.order < $1.order }) {
            var representations: [ClipRepresentation] = []
            let classification = classify(capturedItem, source: capture.source, previewCandidates: &previewCandidates)
            kinds.insert(classification.kind)
            if let metadata = classification.codeMetadata { codeCandidates.append(metadata) }
            for representation in capturedItem.representations.sorted(by: { $0.uti < $1.uti }) {
                totalBytes += representation.data.count
                hasher.update(data: Data(representation.uti.utf8))
                hasher.update(data: representation.data)
                representations.append(ClipRepresentation(uti: representation.uti, storage: .inline(representation.data)))
            }
            convertedItems.append(ClipItem(order: capturedItem.order, representations: representations))
        }

        guard totalBytes > 0 else { return nil }
        let primary = primaryKind(from: kinds)
        let secondary = kinds.subtracting([primary])
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let fileURLs = primary == .file
            ? capture.items.sorted(by: { $0.order < $1.order }).flatMap(FileReferenceDecoder.urls(in:))
            : []
        let fileMetadata: FileClipMetadata? = if fileURLs.isEmpty {
            nil
        } else {
            FileClipMetadata(
                fileNames: fileURLs.enumerated().map { index, url in
                    if FileReferenceDecoder.isOpaqueFileReference(url) { return "文件 \(index + 1)" }
                    return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
                },
                filePaths: {
                    let paths = fileURLs.compactMap(FileReferenceDecoder.stablePath(for:))
                    return paths.count == fileURLs.count ? paths : nil
                }()
            )
        }
        let preview = fileMetadata?.displayName
            ?? previewCandidates.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? defaultPreview(for: primary, itemCount: capture.items.count)

        var clip = Clip(
            createdAt: capture.capturedAt,
            updatedAt: capture.capturedAt,
            lastCopiedAt: capture.capturedAt,
            primaryKind: kinds.count > 1 ? .mixed : primary,
            secondaryKinds: secondary,
            source: capture.source,
            previewText: String(preview.prefix(2_000)),
            contentHash: digest,
            byteSize: totalBytes,
            items: convertedItems,
            codeMetadata: codeCandidates.max(by: { $0.confidence < $1.confidence }),
            fileMetadata: fileMetadata
        )
        clip.identityKey = try? ClipIdentity.key(for: clip)
        return clip
    }

    public static func isColor(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return colorPattern.firstMatch(in: trimmed, range: range) != nil
    }

    public static func isLikelyCode(_ text: String) -> Bool {
        analyzeCode(text, types: [], source: ClipSource()) != nil
    }

    private static func classify(
        _ item: CapturedItem,
        source: ClipSource,
        previewCandidates: inout [String]
    ) -> ItemClassification {
        let types = Set(item.representations.map(\.uti))
        // WeChat also supplies a temporary file URL when copying image pixels.
        // Prefer the embedded image; a file URL alone still represents a file.
        if item.representations.contains(where: {
            !$0.data.isEmpty && UTType($0.uti)?.conforms(to: .image) == true
        }) {
            previewCandidates.append("图像")
            return ItemClassification(kind: .image)
        }
        if types.contains(where: { $0 == "public.file-url" || $0 == "NSFilenamesPboardType" }) {
            previewCandidates.append(filePreview(item))
            return ItemClassification(kind: .file)
        }
        if types.contains(where: { $0 == "com.adobe.pdf" || UTType($0)?.conforms(to: .image) == true }) {
            previewCandidates.append("图像")
            return ItemClassification(kind: .image)
        }
        let text = bestText(item)
        if types.contains("public.url") || types.contains("public.url-name") || text.flatMap(URL.init(string:))?.scheme != nil {
            previewCandidates.append(text ?? "链接")
            return ItemClassification(kind: .link)
        }
        if types.contains("com.apple.cocoa.pasteboard.color") || types.contains("NSColorPboardType") || text.map(isColor) == true {
            previewCandidates.append(text ?? "颜色")
            return ItemClassification(kind: .color)
        }
        if let text {
            previewCandidates.append(text)
            if let metadata = analyzeCode(text, types: types, source: source) {
                return ItemClassification(kind: .code, codeMetadata: metadata)
            }
            return ItemClassification(kind: .text)
        }
        return ItemClassification(kind: .text)
    }

    private static func bestText(_ item: CapturedItem) -> String? {
        let preferred = ["public.utf8-plain-text", "public.utf16-plain-text", "public.text", "NSStringPboardType", "public.url"]
        let representations = item.representations.sorted { lhs, rhs in
            let lhsSource = UTType(lhs.uti)?.conforms(to: .sourceCode) == true
            let rhsSource = UTType(rhs.uti)?.conforms(to: .sourceCode) == true
            if lhsSource != rhsSource { return lhsSource }
            return (preferred.firstIndex(of: lhs.uti) ?? .max) < (preferred.firstIndex(of: rhs.uti) ?? .max)
        }
        for representation in representations {
            let type = UTType(representation.uti)
            guard preferred.contains(representation.uti)
                    || type?.conforms(to: .sourceCode) == true
                    || type?.conforms(to: .text) == true else { continue }
            if let value = String(data: representation.data, encoding: .utf8)
                ?? String(data: representation.data, encoding: .utf16) {
                return value
            }
        }
        return nil
    }

    private static func analyzeCode(_ text: String, types: Set<String>, source: ClipSource) -> CodeMetadata? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        let sample = String(trimmed.prefix(maximumClassificationCharacters))
        let wasTruncated = trimmed.count > sample.count
        let allLines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = allLines.prefix(maximumClassificationLines).map(String.init)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmptyLines.isEmpty else { return nil }

        let explicitSourceType = types.contains { UTType($0)?.conforms(to: .sourceCode) == true }
        let explicitLanguage = language(from: types)
        let features = CodeFeatures(text: sample, lines: nonEmptyLines)

        if explicitSourceType {
            let inferred = explicitLanguage ?? bestLanguage(from: features, source: source).language
            return metadata(
                subtype: inferred == .shell ? .shellCommand : .sourceCode,
                language: inferred,
                confidence: 1,
                features: features,
                sample: sample,
                originalText: trimmed,
                wasTruncated: wasTruncated || allLines.count > lines.count
            )
        }

        if let explicitLanguage, [.json, .yaml, .xml, .css].contains(explicitLanguage) {
            return metadata(
                subtype: .structuredData,
                language: explicitLanguage,
                confidence: 0.98,
                features: features,
                sample: sample,
                originalText: trimmed,
                wasTruncated: wasTruncated || allLines.count > lines.count
            )
        }

        if features.isJSON {
            return metadata(subtype: .structuredData, language: .json, confidence: 0.98, features: features, sample: sample, originalText: trimmed, wasTruncated: wasTruncated)
        }
        if features.isDiff {
            return metadata(subtype: .diff, confidence: 0.96, features: features, sample: sample, originalText: trimmed, wasTruncated: wasTruncated)
        }

        let candidate = bestLanguage(from: features, source: source)
        var score = candidate.score
        if nonEmptyLines.count > 1 {
            score += min(features.codeLineRatio * 0.28, 0.28)
            score += 0.04
        } else if features.codeLikeLineCount == 1 {
            score += 0.12
        }
        if features.indentedLineRatio >= 0.2 { score += 0.08 }
        if features.hasStrongStructure { score += 0.08 }
        if isEditor(source) { score += 0.14 }
        if candidate.language == .shell, isTerminal(source) { score += 0.12 }
        if features.sentenceLineRatio >= 0.6 { score -= 0.28 }

        let threshold: Double
        if candidate.language == .shell || candidate.language == .sql { threshold = 0.52 }
        else if nonEmptyLines.count == 1 { threshold = isEditor(source) ? 0.56 : 0.68 }
        else { threshold = 0.50 }

        guard score >= threshold, features.codeLineRatio >= 0.25 || candidate.score >= 0.45 else { return nil }
        let subtype: CodeSubtype = switch candidate.language {
        case .shell: .shellCommand
        case .json, .yaml, .xml: .structuredData
        default: .sourceCode
        }
        return metadata(
            subtype: subtype,
            language: candidate.language,
            confidence: min(max(score, threshold), 0.99),
            features: features,
            sample: sample,
            originalText: trimmed,
            wasTruncated: wasTruncated || allLines.count > lines.count
        )
    }

    private static func metadata(
        subtype: CodeSubtype,
        language: CodeLanguage? = nil,
        confidence: Double,
        features: CodeFeatures,
        sample: String,
        originalText: String,
        wasTruncated: Bool
    ) -> CodeMetadata {
        CodeMetadata(
            subtype: subtype,
            language: language,
            confidence: confidence,
            codeLineRatio: features.codeLineRatio,
            analyzedCharacterCount: sample.count,
            wasTruncatedForClassification: wasTruncated,
            totalLineCount: lineCount(in: originalText),
            totalCharacterCount: originalText.count
        )
    }

    private static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    private static func bestLanguage(from features: CodeFeatures, source: ClipSource) -> LanguageCandidate {
        let tokens = features.tokens
        func has(_ token: String) -> Bool { tokens.contains(token) }
        func any(_ values: String...) -> Bool { values.contains(where: has) }

        var scores = [CodeLanguage: Double]()
        scores[.swift] = (has("func") ? 0.28 : 0)
            + (has("import") ? 0.12 : 0)
            + (any("let", "var", "guard") ? 0.12 : 0)
            + (any("protocol", "extension") ? 0.15 : 0)
            + (features.text.contains("->") ? 0.12 : 0)
        scores[.kotlin] = (has("fun") ? 0.28 : 0)
            + (any("val", "var", "when") ? 0.12 : 0)
            + (any("suspend", "companion") ? 0.14 : 0)
            + (has("package") ? 0.10 : 0)
            + (has("data") && has("class") ? 0.16 : 0)
        scores[.java] = (has("public") && any("class", "interface", "enum") ? 0.30 : 0)
            + (has("package") ? 0.12 : 0)
            + (has("import") ? 0.10 : 0)
            + (any("private", "protected", "static") ? 0.12 : 0)
            + (has("new") ? 0.08 : 0)
        scores[.python] = (has("def") ? 0.30 : 0)
            + (has("from") && has("import") ? 0.16 : 0)
            + (any("return", "yield", "elif", "self") ? 0.12 : 0)
            + (features.hasColonIndentation ? 0.14 : 0)
        scores[.typescript] = (any("interface", "type", "namespace") ? 0.22 : 0)
            + (any("const", "let", "function") ? 0.12 : 0)
            + (any("import", "export") ? 0.12 : 0)
            + (features.text.contains("=>") ? 0.18 : 0)
        scores[.javascript] = (any("const", "let", "function") ? 0.16 : 0)
            + (any("import", "export", "require") ? 0.12 : 0)
            + (features.text.contains("=>") ? 0.20 : 0)
        scores[.shell] = (features.hasShebang ? 0.48 : 0)
            + (any("git", "npm", "pnpm", "yarn", "curl", "sudo", "brew", "make", "swift") ? 0.42 : 0)
            + (features.text.contains("&&") || features.text.contains("||") || features.text.contains(" | ") ? 0.16 : 0)
            + (features.text.contains("${") ? 0.10 : 0)
        scores[.sql] = (has("select") && has("from") ? 0.52 : 0)
            + (has("insert") && has("into") ? 0.52 : 0)
            + (has("update") && has("set") ? 0.52 : 0)
            + (has("delete") && has("from") ? 0.52 : 0)
            + (any("where", "join", "group", "order") ? 0.10 : 0)
        scores[.yaml] = features.yamlLineRatio >= 0.6 ? 0.52 : 0
        scores[.html] = features.looksLikeHTML ? 0.58 : 0
        scores[.xml] = features.looksLikeXML ? 0.58 : 0
        scores[.css] = features.looksLikeCSS ? 0.55 : 0

        let sourceValue = "\(source.bundleIdentifier ?? "") \(source.appName)".lowercased()
        if sourceValue.contains("xcode") { scores[.swift, default: 0] += 0.12 }
        if sourceValue.contains("android studio") || sourceValue.contains("intellij") {
            scores[.kotlin, default: 0] += 0.08
            scores[.java, default: 0] += 0.05
        }

        let best = scores.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key.rawValue > rhs.key.rawValue }
            return lhs.value < rhs.value
        }
        return LanguageCandidate(language: best?.value == 0 ? nil : best?.key, score: best?.value ?? 0)
    }

    private static func language(from types: Set<String>) -> CodeLanguage? {
        let joined = types.joined(separator: " ").lowercased()
        if joined.contains("swift") { return .swift }
        if joined.contains("kotlin") { return .kotlin }
        if joined.contains("java") && !joined.contains("javascript") { return .java }
        if joined.contains("javascript") { return .javascript }
        if joined.contains("typescript") { return .typescript }
        if joined.contains("python") { return .python }
        if joined.contains("shell") || joined.contains("script") { return .shell }
        if joined.contains("json") { return .json }
        if joined.contains("yaml") || joined.contains("yml") { return .yaml }
        if joined.contains("xml") { return .xml }
        if joined.contains("css") { return .css }
        return nil
    }

    private static func isEditor(_ source: ClipSource) -> Bool {
        let value = "\(source.bundleIdentifier ?? "") \(source.appName)".lowercased()
        return ["xcode", "vscode", "visual studio code", "jetbrains", "intellij", "android studio", "sublime", "nova", "zed", "cursor", "coteditor"]
            .contains { value.contains($0) }
    }

    private static func isTerminal(_ source: ClipSource) -> Bool {
        let value = "\(source.bundleIdentifier ?? "") \(source.appName)".lowercased()
        return ["terminal", "iterm", "warp"].contains { value.contains($0) }
    }

    private static func filePreview(_ item: CapturedItem) -> String {
        guard let url = FileReferenceDecoder.urls(in: item).first else { return "文件" }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private static func primaryKind(from kinds: Set<ClipKind>) -> ClipKind {
        for kind in [ClipKind.file, .image, .link, .color, .code, .text] where kinds.contains(kind) { return kind }
        return .text
    }

    private static func defaultPreview(for kind: ClipKind, itemCount: Int) -> String {
        itemCount > 1 ? "\(itemCount) 项\(kind.displayName)" : kind.displayName
    }
}

private struct ItemClassification {
    var kind: ClipKind
    var codeMetadata: CodeMetadata?

    init(kind: ClipKind, codeMetadata: CodeMetadata? = nil) {
        self.kind = kind
        self.codeMetadata = codeMetadata
    }
}

private struct LanguageCandidate {
    var language: CodeLanguage?
    var score: Double
}

private struct CodeFeatures {
    let text: String
    let tokens: Set<String>
    let codeLikeLineCount: Int
    let codeLineRatio: Double
    let indentedLineRatio: Double
    let sentenceLineRatio: Double
    let yamlLineRatio: Double
    let hasStrongStructure: Bool
    let hasColonIndentation: Bool
    let hasShebang: Bool
    let isJSON: Bool
    let isDiff: Bool
    let looksLikeHTML: Bool
    let looksLikeXML: Bool
    let looksLikeCSS: Bool

    init(text: String, lines: [String]) {
        self.text = text
        let lowercased = text.lowercased()
        self.tokens = Set(lowercased.split { character in
            !(character.isLetter || character.isNumber || character == "_" || character == "#")
        }.map(String.init))

        let strongTokens: Set<String> = [
            "func", "fun", "def", "class", "struct", "interface", "protocol", "import", "package",
            "return", "guard", "select", "insert", "update", "delete", "git", "curl", "sudo"
        ]
        var codeLike = 0
        var indented = 0
        var sentences = 0
        var yamlLines = 0
        var colonIndentation = false
        var previousEndedWithColon = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineTokens = Set(trimmed.lowercased().split { character in
                !(character.isLetter || character.isNumber || character == "_" || character == "#")
            }.map(String.init))
            let isIndented = line.first?.isWhitespace == true
            if isIndented { indented += 1 }
            if previousEndedWithColon && isIndented { colonIndentation = true }
            previousEndedWithColon = trimmed.hasSuffix(":")

            let punctuationSignals = ["=", "=>", "->", "&&", "||", "::", "{", "}", "(", ")", ";"]
                .filter { trimmed.contains($0) }.count
            let startsLikeCode = ["//", "/*", "* ", "#", "--", "+", "-"].contains { trimmed.hasPrefix($0) }
            let hasStrongToken = !lineTokens.isDisjoint(with: strongTokens)
            if hasStrongToken || startsLikeCode || punctuationSignals >= 2 { codeLike += 1 }
            if trimmed.hasSuffix("。") || trimmed.hasSuffix("！") || trimmed.hasSuffix("？")
                || trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
                sentences += 1
            }
            if trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*\s*:\s*\S+"#, options: .regularExpression) != nil {
                yamlLines += 1
            }
        }

        let count = max(lines.count, 1)
        self.codeLikeLineCount = codeLike
        self.codeLineRatio = Double(codeLike) / Double(count)
        self.indentedLineRatio = Double(indented) / Double(count)
        self.sentenceLineRatio = Double(sentences) / Double(count)
        self.yamlLineRatio = Double(yamlLines) / Double(count)
        self.hasColonIndentation = colonIndentation
        self.hasShebang = lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("#!") == true
        self.hasStrongStructure = text.contains("=>") || text.contains("->") || text.contains("&&")
            || text.contains("||") || (text.contains("{") && text.contains("}"))
        self.isDiff = text.contains("diff --git") || (text.contains("@@") && lines.filter { $0.hasPrefix("+") || $0.hasPrefix("-") }.count >= 2)

        let jsonData = Data(text.utf8)
        let startsAsJSON = text.hasPrefix("{") || text.hasPrefix("[")
        self.isJSON = startsAsJSON && (try? JSONSerialization.jsonObject(with: jsonData)) != nil
        self.looksLikeHTML = text.range(of: #"(?is)<(?:!doctype\s+html|html|body|div|span|script|style|a|p|section|main|header|footer|button|input|form|ul|li|h[1-6])\b[^>]*>"#, options: .regularExpression) != nil
        self.looksLikeXML = !looksLikeHTML && text.range(of: #"(?s)^\s*<\?xml\b|^\s*<[A-Za-z_][\w:.-]*\b[^>]*>"#, options: .regularExpression) != nil
        self.looksLikeCSS = text.range(of: #"(?s)[.#]?[A-Za-z_][\w-]*\s*\{[^}]*[A-Za-z-]+\s*:\s*[^;}]+[;}]"#, options: .regularExpression) != nil
    }
}

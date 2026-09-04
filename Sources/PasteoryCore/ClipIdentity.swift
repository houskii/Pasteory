import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum ClipIdentity {
    public typealias RepresentationDataLoader = (ClipRepresentation) throws -> Data

    public static func key(
        for clip: Clip,
        loadData: RepresentationDataLoader = inlineData
    ) throws -> String? {
        switch clip.primaryKind {
        case .text, .code, .color:
            let values = try orderedItems(in: clip).compactMap { item in
                try bestText(in: item, loadData: loadData)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !values.isEmpty else { return nil }
            return "v2:text:\(digest(values: values, using: SHA256.self))"

        case .link:
            let values = try orderedItems(in: clip).compactMap { item -> String? in
                guard let text = try bestText(in: item, loadData: loadData),
                      let url = URLFallbackEngine.normalizedWebURL(text) else { return nil }
                return URLFallbackEngine.canonicalResourceKey(for: url)
            }
            guard !values.isEmpty else { return nil }
            return "v2:link:\(digest(values: values, using: SHA256.self))"

        case .image:
            let checksums = try orderedItems(in: clip).compactMap { item -> String? in
                guard let representation = preferredImageRepresentation(in: item) else { return nil }
                return md5(try loadData(representation))
            }
            guard !checksums.isEmpty else { return nil }
            return "v2:image:\(checksums.joined(separator: ","))"

        case .file:
            let urls = try orderedItems(in: clip).flatMap { item in
                try fileURLs(in: item, loadData: loadData)
            }
            guard !urls.isEmpty else { return nil }
            let checksums = try urls.map(md5OfFile(at:))
            return "v2:file:\(checksums.joined(separator: ","))"

        case .mixed:
            return nil
        }
    }

    public static func inlineData(for representation: ClipRepresentation) throws -> Data {
        guard case .inline(let data) = representation.storage else {
            throw ClipIdentityError.externalRepresentationNeedsLoader
        }
        return data
    }

    private static func orderedItems(in clip: Clip) -> [ClipItem] {
        clip.items.sorted { $0.order < $1.order }
    }

    private static func bestText(
        in item: ClipItem,
        loadData: RepresentationDataLoader
    ) throws -> String? {
        let preferred = [
            "public.utf8-plain-text",
            "public.utf16-plain-text",
            "public.text",
            "NSStringPboardType",
            "public.url"
        ]
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
            let data = try loadData(representation)
            if let value = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) {
                return value
            }
        }
        return nil
    }

    private static func preferredImageRepresentation(in item: ClipItem) -> ClipRepresentation? {
        let preferred = ["public.png", "public.jpeg", "public.heic", "public.tiff", "com.adobe.pdf"]
        return item.representations
            .filter { $0.uti == "com.adobe.pdf" || UTType($0.uti)?.conforms(to: .image) == true }
            .sorted {
                let lhs = preferred.firstIndex(of: $0.uti) ?? .max
                let rhs = preferred.firstIndex(of: $1.uti) ?? .max
                if lhs != rhs { return lhs < rhs }
                return $0.uti < $1.uti
            }
            .first
    }

    private static func fileURLs(
        in item: ClipItem,
        loadData: RepresentationDataLoader
    ) throws -> [URL] {
        try FileReferenceDecoder.urls(in: item, loadData: loadData)
    }

    private static func digest<H: HashFunction>(values: [String], using type: H.Type) -> String {
        var hasher = H()
        for value in values {
            let data = Data(value.utf8)
            hasher.update(data: Data("\(data.count):".utf8))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func md5OfFile(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ClipIdentityError.notRegularFile(url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ClipIdentityError: Error {
    case externalRepresentationNeedsLoader
    case notRegularFile(URL)
}

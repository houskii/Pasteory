import AppKit
import ApplicationServices
import Foundation
import PasteoryCore

@MainActor
final class SourceContextCaptureCoordinator {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func captureContext(for source: ClipSource, copiedText: String, capturedAt: Date) async -> CapturedSourceContext? {
        if settings.isSourceCaptureEnabled(for: .chrome), !copiedText.isEmpty {
            let attempts = SourceCaptureApplication.application(for: source.bundleIdentifier) == .chrome ? 5 : 1
            for attempt in 0..<attempts {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(40)) }
                let payload = await Task.detached(priority: .userInitiated) {
                    ChromeContextInbox.takeMatching(copiedText: copiedText, now: capturedAt)
                }.value
                if let payload { return payload.sourceContext() }
            }
        }
        guard let application = SourceCaptureApplication.application(for: source.bundleIdentifier),
              settings.isSourceCaptureEnabled(for: application) else { return nil }
        switch application {
        case .chrome:
            return nil
        case .wechat:
            guard let processIdentifier = source.processIdentifier else { return nil }
            return await Task.detached(priority: .userInitiated) {
                AccessibilityConversationCapture.wechat(processIdentifier: processIdentifier)
            }.value
        case .lark:
            guard let processIdentifier = source.processIdentifier else { return nil }
            return await Task.detached(priority: .userInitiated) {
                AccessibilityConversationCapture.lark(processIdentifier: processIdentifier)
            }.value
        }
    }
}

enum AccessibilityConversationCapture {
    private struct QueueItem {
        var element: AXUIElement
        var depth: Int
    }

    static func wechat(processIdentifier: Int32) -> CapturedSourceContext? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid_t(processIdentifier))
        let searchRoot = elementAttribute(application, name: kAXFocusedWindowAttribute as CFString) ?? application
        guard let target = firstDescendant(
            of: searchRoot,
            maximumDepth: 40,
            maximumNodes: 5_000,
            timeout: 0.30,
            matching: { stringAttribute($0, name: kAXIdentifierAttribute as CFString) == "current_chat_name_label" }
        ), let conversation = nonEmpty(stringAttribute(target, name: kAXValueAttribute as CFString)) else { return nil }
        let titleLine = parent(of: target)
        let titleWithCount = titleLine.flatMap { stringAttribute($0, name: kAXValueAttribute as CFString) }
        let header = titleLine.flatMap(parent(of:))
        let hasCallButton = header.flatMap {
            firstDescendant(
                of: $0,
                maximumDepth: 3,
                maximumNodes: 40,
                timeout: 0.03,
                matching: { stringAttribute($0, name: kAXIdentifierAttribute as CFString) == "voip_button" }
            )
        } != nil
        let detection = ConversationContextDetector.wechat(headerTitle: titleWithCount, hasCallButton: hasCallButton)
        return conversationContext(
            applicationName: "微信",
            conversation: conversation,
            conversationType: detection.type,
            participantCount: detection.participantCount,
            strategyIdentifier: "wechat.ax.conversation.v1"
        )
    }

    static func lark(processIdentifier: Int32) -> CapturedSourceContext? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid_t(processIdentifier))
        let searchRoot = elementAttribute(application, name: kAXFocusedWindowAttribute as CFString) ?? application
        guard let webArea = firstDescendant(
            of: searchRoot,
            maximumDepth: 40,
            maximumNodes: 8_000,
            timeout: 0.40,
            matching: { element in
                stringAttribute(element, name: kAXRoleAttribute as CFString) == "AXWebArea"
                    && (stringAttribute(element, name: kAXURLAttribute as CFString)?.contains("/messenger-chat/") == true)
            }
        ), let nameContainer = firstDescendant(
            of: webArea,
            maximumDepth: 40,
            maximumNodes: 8_000,
            timeout: 0.40,
            matching: { domClasses($0).contains("chatWindow_chatName") }
        ), let conversation = firstTextValue(in: nameContainer, maximumDepth: 4) else { return nil }
        let header = parent(of: nameContainer)
        let countContainer = header.flatMap {
            firstDescendant(
                of: $0,
                maximumDepth: 5,
                maximumNodes: 120,
                timeout: 0.05,
                matching: { domClasses($0).contains("chatNewWindow_count") }
            )
        }
        let participantCount = countContainer.flatMap {
            firstTextValue(in: $0, maximumDepth: 3)
        }.flatMap(firstInteger(in:))
        let hasBotCount = header.flatMap {
            firstDescendant(
                of: $0,
                maximumDepth: 5,
                maximumNodes: 120,
                timeout: 0.05,
                matching: { domClasses($0).contains("chatWindow_botCount") }
            )
        }.flatMap { firstTextValue(in: $0, maximumDepth: 3) } != nil
        let detection = ConversationContextDetector.lark(
            participantCount: participantCount,
            hasBotCount: hasBotCount
        )
        return conversationContext(
            applicationName: "飞书",
            conversation: conversation,
            conversationType: detection.type,
            participantCount: detection.participantCount,
            strategyIdentifier: "lark.ax.conversation.v1"
        )
    }

#if DEBUG
    static func debugStructure(processIdentifier: Int32, application: SourceCaptureApplication) -> [String] {
        let root = AXUIElementCreateApplication(pid_t(processIdentifier))
        let target: AXUIElement?
        switch application {
        case .wechat:
            target = firstDescendant(
                of: root,
                maximumDepth: 40,
                maximumNodes: 8_000,
                timeout: 0.8,
                matching: { stringAttribute($0, name: kAXIdentifierAttribute as CFString) == "current_chat_name_label" }
            )
        case .lark:
            target = firstDescendant(
                of: root,
                maximumDepth: 40,
                maximumNodes: 12_000,
                timeout: 0.8,
                matching: { domClasses($0).contains("chatWindow_chatName") }
            )
        case .chrome:
            target = nil
        }
        guard let target else { return ["target=missing"] }
        var lines = [String]()
        var current: AXUIElement? = target
        for level in 0..<9 {
            guard let element = current else { break }
            lines.append("level=\(level) \(structureDescription(element))")
            for (index, child) in children(of: element).prefix(12).enumerated() {
                lines.append("level=\(level) child=\(index) \(structureDescription(child))")
            }
            current = parent(of: element)
        }
        if let header = parent(of: target) {
            var queue = [QueueItem(element: header, depth: 0)]
            var cursor = 0
            while cursor < queue.count, cursor < 160 {
                let item = queue[cursor]
                cursor += 1
                lines.append("headerDepth=\(item.depth) \(structureDescription(item.element))")
                if item.depth < 5 {
                    queue.append(contentsOf: children(of: item.element).map {
                        QueueItem(element: $0, depth: item.depth + 1)
                    })
                }
            }
        }
        return lines
    }

    private static func structureDescription(_ element: AXUIElement) -> String {
        let role = stringAttribute(element, name: kAXRoleAttribute as CFString) ?? ""
        let identifier = stringAttribute(element, name: kAXIdentifierAttribute as CFString) ?? ""
        let description = stringAttribute(element, name: kAXDescriptionAttribute as CFString) ?? ""
        return "role=\(role) id=\(identifier) description=\(description) classes=\(domClasses(element).joined(separator: ","))"
    }
#endif

    private static func conversationContext(
        applicationName: String,
        conversation: String,
        conversationType: ConversationContextType,
        participantCount: Int?,
        strategyIdentifier: String
    ) -> CapturedSourceContext {
        var payload = [
            "application": applicationName,
            "conversationName": conversation,
            "conversationType": conversationType.rawValue,
            "conversationTypeName": conversationType.displayName
        ]
        if let participantCount { payload["participantCount"] = String(participantCount) }
        var entityMetadata = ["conversationType": conversationType.rawValue]
        if let participantCount { entityMetadata["participantCount"] = String(participantCount) }
        var entities = [
            SourceContextEntity(
                kind: .conversation,
                provider: strategyIdentifier,
                displayName: conversation,
                identityQuality: .displayNameOnly,
                metadata: entityMetadata
            )
        ]
        if conversationType == .direct {
            entities.append(SourceContextEntity(
                kind: .person,
                provider: strategyIdentifier,
                displayName: conversation,
                identityQuality: .displayNameOnly,
                metadata: ["derivedFrom": "directConversationTitle"]
            ))
        }
        return CapturedSourceContext(
            kind: .conversation,
            sourceCategory: .communication,
            strategyIdentifier: strategyIdentifier,
            summary: "\(conversationType.displayName)｜\(conversation)",
            payload: payload,
            entities: entities
        )
    }

    private static func firstInteger(in value: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: #"\d+"#),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return nil }
        return Int(value[range])
    }

    private static func firstDescendant(
        of root: AXUIElement,
        maximumDepth: Int,
        maximumNodes: Int,
        timeout: TimeInterval,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        var queue = [QueueItem(element: root, depth: 0)]
        var cursor = 0
        var visited = 0
        while cursor < queue.count, visited < maximumNodes, CFAbsoluteTimeGetCurrent() < deadline {
            let item = queue[cursor]
            cursor += 1
            visited += 1
            if predicate(item.element) { return item.element }
            guard item.depth < maximumDepth else { continue }
            for child in children(of: item.element) {
                queue.append(QueueItem(element: child, depth: item.depth + 1))
            }
        }
        return nil
    }

    private static func firstTextValue(in root: AXUIElement, maximumDepth: Int) -> String? {
        firstDescendant(
            of: root,
            maximumDepth: maximumDepth,
            maximumNodes: 80,
            timeout: 0.03,
            matching: { element in
                stringAttribute(element, name: kAXRoleAttribute as CFString) == "AXStaticText"
                    && nonEmpty(stringAttribute(element, name: kAXValueAttribute as CFString)) != nil
            }
        ).flatMap { nonEmpty(stringAttribute($0, name: kAXValueAttribute as CFString)) }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeDowncast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            return Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
        }
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elementAttribute(_ element: AXUIElement, name: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ element: AXUIElement, name: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        if let text = value as? String { return text }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func domClasses(_ element: AXUIElement) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &value) == .success else { return [] }
        if let classes = value as? [String] { return classes }
        if let classes = value as? String { return classes.split(separator: " ").map(String.init) }
        return []
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(512))
    }
}

#if DEBUG
@MainActor
enum DebugSourceContextProbe {
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--debug-source-context"), arguments.indices.contains(index + 1),
              let application = SourceCaptureApplication(rawValue: arguments[index + 1]) else { return false }
        guard let running = application.bundleIdentifiers.lazy.compactMap({
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }).first else {
            print("source-context-probe=application-not-running")
            return true
        }
        print("source-context-probe=ax-trusted-\(AXIsProcessTrusted()) pid-\(running.processIdentifier)")
        if arguments.contains("--debug-source-context-structure") {
            for line in AccessibilityConversationCapture.debugStructure(
                processIdentifier: running.processIdentifier,
                application: application
            ) { print(line) }
        }
        let context: CapturedSourceContext?
        switch application {
        case .wechat:
            context = AccessibilityConversationCapture.wechat(processIdentifier: running.processIdentifier)
        case .lark:
            context = AccessibilityConversationCapture.lark(processIdentifier: running.processIdentifier)
        case .chrome:
            context = nil
        }
        guard let context, let data = try? JSONEncoder().encode(context), let output = String(data: data, encoding: .utf8) else {
            print("source-context-probe=no-context")
            return true
        }
        print(output)
        return true
    }
}
#endif

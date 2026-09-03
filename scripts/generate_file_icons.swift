#!/usr/bin/env swift

import Foundation

struct FileIconSpec {
    let key: String
    let label: String
    let title: String
    let examples: String
    let accent: String
    let accentEnd: String
    let labelForeground: String
    let glyph: String
}

let specs: [FileIconSpec] = [
    .init(key: "txt", label: "TXT", title: "纯文本", examples: "txt · text", accent: "#64748B", accentEnd: "#475569", labelForeground: "#FFFFFF", glyph: "text"),
    .init(key: "markdown", label: "MD", title: "Markdown", examples: "md · markdown", accent: "#334155", accentEnd: "#0F172A", labelForeground: "#FFFFFF", glyph: "markdown"),
    .init(key: "pdf", label: "PDF", title: "PDF", examples: "pdf", accent: "#DC2626", accentEnd: "#991B1B", labelForeground: "#FFFFFF", glyph: "document"),
    .init(key: "document", label: "DOC", title: "文档", examples: "docx · pages · rtf", accent: "#2563EB", accentEnd: "#1D4ED8", labelForeground: "#FFFFFF", glyph: "text"),
    .init(key: "spreadsheet", label: "XLS", title: "表格", examples: "xlsx · numbers · csv", accent: "#16A34A", accentEnd: "#15803D", labelForeground: "#FFFFFF", glyph: "table"),
    .init(key: "presentation", label: "PPT", title: "演示文稿", examples: "pptx · key", accent: "#EA580C", accentEnd: "#C2410C", labelForeground: "#FFFFFF", glyph: "slides"),
    .init(key: "image", label: "IMG", title: "图片回退", examples: "png · jpg · heic", accent: "#DB2777", accentEnd: "#BE185D", labelForeground: "#FFFFFF", glyph: "image"),
    .init(key: "audio", label: "AUD", title: "音频", examples: "mp3 · m4a · wav", accent: "#7C3AED", accentEnd: "#6D28D9", labelForeground: "#FFFFFF", glyph: "audio"),
    .init(key: "video", label: "VID", title: "视频", examples: "mp4 · mov · webm", accent: "#9333EA", accentEnd: "#7E22CE", labelForeground: "#FFFFFF", glyph: "video"),
    .init(key: "archive", label: "ZIP", title: "压缩包", examples: "zip · 7z · tar.gz", accent: "#CA8A04", accentEnd: "#A16207", labelForeground: "#FFFFFF", glyph: "archive"),
    .init(key: "installer", label: "PKG", title: "安装与镜像", examples: "dmg · pkg · iso", accent: "#0D9488", accentEnd: "#0F766E", labelForeground: "#FFFFFF", glyph: "package"),
    .init(key: "font", label: "FONT", title: "字体", examples: "ttf · otf · woff2", accent: "#4F46E5", accentEnd: "#4338CA", labelForeground: "#FFFFFF", glyph: "font"),

    .init(key: "json", label: "JSON", title: "JSON", examples: "json · json5", accent: "#D97706", accentEnd: "#B45309", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "yaml", label: "YAML", title: "YAML", examples: "yaml · yml", accent: "#C2410C", accentEnd: "#9A3412", labelForeground: "#FFFFFF", glyph: "config"),
    .init(key: "xml", label: "XML", title: "XML", examples: "xml", accent: "#EA580C", accentEnd: "#C2410C", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "config", label: "CFG", title: "配置", examples: "toml · ini · plist · env", accent: "#64748B", accentEnd: "#475569", labelForeground: "#FFFFFF", glyph: "config"),
    .init(key: "database", label: "DB", title: "数据库", examples: "db · sqlite3 · realm", accent: "#0891B2", accentEnd: "#0E7490", labelForeground: "#FFFFFF", glyph: "database"),
    .init(key: "shell", label: "SH", title: "Shell", examples: "sh · zsh · bash", accent: "#1F2937", accentEnd: "#111827", labelForeground: "#FFFFFF", glyph: "shell"),
    .init(key: "api", label: "API", title: "接口定义", examples: "proto · thrift · gql", accent: "#6366F1", accentEnd: "#4F46E5", labelForeground: "#FFFFFF", glyph: "api"),
    .init(key: "diff", label: "DIFF", title: "补丁与差异", examples: "patch · diff", accent: "#D97706", accentEnd: "#B45309", labelForeground: "#FFFFFF", glyph: "diff"),
    .init(key: "log", label: "LOG", title: "日志", examples: "log · trace", accent: "#F97316", accentEnd: "#EA580C", labelForeground: "#FFFFFF", glyph: "log"),
    .init(key: "lock", label: "LOCK", title: "依赖锁定", examples: "lock · resolved", accent: "#64748B", accentEnd: "#334155", labelForeground: "#FFFFFF", glyph: "lock"),

    .init(key: "swift", label: "SWIFT", title: "Swift", examples: "swift · interface", accent: "#F05138", accentEnd: "#D63B27", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "objc", label: "OBJ-C", title: "Objective-C", examples: "m · mm · h", accent: "#3B82F6", accentEnd: "#2563EB", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "cpp", label: "C++", title: "C 与 C++", examples: "c · cc · cpp · hpp", accent: "#00599C", accentEnd: "#004482", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "xcode", label: "XCODE", title: "Xcode 工程", examples: "xcodeproj · workspace", accent: "#147EFB", accentEnd: "#0B65D8", labelForeground: "#FFFFFF", glyph: "project"),
    .init(key: "ios-package", label: "IPA", title: "Apple 构建产物", examples: "ipa · app · archive", accent: "#0EA5E9", accentEnd: "#0284C7", labelForeground: "#FFFFFF", glyph: "package"),
    .init(key: "certificate", label: "CERT", title: "证书与签名", examples: "p12 · cer · provision", accent: "#B91C1C", accentEnd: "#991B1B", labelForeground: "#FFFFFF", glyph: "certificate"),

    .init(key: "kotlin", label: "KT", title: "Kotlin", examples: "kt · kts", accent: "#7F52FF", accentEnd: "#5B2FD6", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "java", label: "JAVA", title: "Java", examples: "java", accent: "#E76F00", accentEnd: "#C75E00", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "android-package", label: "APK", title: "Android 安装包", examples: "apk · aab", accent: "#3DDC84", accentEnd: "#16A763", labelForeground: "#123524", glyph: "package"),
    .init(key: "android-library", label: "AAR", title: "Android 库", examples: "aar · jar", accent: "#22C55E", accentEnd: "#16A34A", labelForeground: "#FFFFFF", glyph: "project"),
    .init(key: "binary", label: "BIN", title: "二进制与原生库", examples: "so · dex · wasm", accent: "#475569", accentEnd: "#1E293B", labelForeground: "#FFFFFF", glyph: "binary"),
    .init(key: "diagnostic", label: "DEBUG", title: "诊断文件", examples: "crash · ips · hprof", accent: "#F97316", accentEnd: "#DC2626", labelForeground: "#FFFFFF", glyph: "diagnostic"),
    .init(key: "network", label: "NET", title: "网络抓包", examples: "har · pcap · pcapng", accent: "#06B6D4", accentEnd: "#0284C7", labelForeground: "#FFFFFF", glyph: "api"),

    .init(key: "arkts", label: "ETS", title: "ArkTS", examples: "ets", accent: "#0A84FF", accentEnd: "#006EDC", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "harmony-package", label: "HAP", title: "HarmonyOS 包", examples: "hap · hsp · har", accent: "#2563EB", accentEnd: "#4F46E5", labelForeground: "#FFFFFF", glyph: "package"),
    .init(key: "javascript", label: "JS", title: "JavaScript", examples: "js · jsx · mjs", accent: "#F7DF1E", accentEnd: "#EAB308", labelForeground: "#2D2D2D", glyph: "code"),
    .init(key: "typescript", label: "TS", title: "TypeScript", examples: "ts · tsx", accent: "#3178C6", accentEnd: "#235A97", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "web", label: "WEB", title: "Web 页面与样式", examples: "html · css · vue", accent: "#E44D26", accentEnd: "#264DE4", labelForeground: "#FFFFFF", glyph: "web"),
    .init(key: "dart", label: "DART", title: "Dart 与 Flutter", examples: "dart", accent: "#0175C2", accentEnd: "#02569B", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "python", label: "PY", title: "Python", examples: "py · pyi", accent: "#3776AB", accentEnd: "#FFD43B", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "go", label: "GO", title: "Go", examples: "go", accent: "#00ADD8", accentEnd: "#007D9C", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "rust", label: "RS", title: "Rust", examples: "rs", accent: "#B7410E", accentEnd: "#7C2D12", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "ruby", label: "RB", title: "Ruby", examples: "rb", accent: "#CC342D", accentEnd: "#9B1C1C", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "lua", label: "LUA", title: "Lua", examples: "lua", accent: "#2C2D72", accentEnd: "#11124F", labelForeground: "#FFFFFF", glyph: "code"),
    .init(key: "build", label: "BUILD", title: "构建脚本", examples: "Makefile · Gradle", accent: "#475569", accentEnd: "#0F172A", labelForeground: "#FFFFFF", glyph: "build"),
    .init(key: "git", label: "GIT", title: "版本控制", examples: ".gitignore · Git", accent: "#F05032", accentEnd: "#C93D24", labelForeground: "#FFFFFF", glyph: "git"),
    .init(key: "generic", label: "FILE", title: "通用文件", examples: "未知或无后缀", accent: "#64748B", accentEnd: "#334155", labelForeground: "#FFFFFF", glyph: "document")
]

func escaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func glyphMarkup(_ glyph: String, accent: String) -> String {
    let common = "stroke=\"\(accent)\" stroke-linecap=\"round\" stroke-linejoin=\"round\" fill=\"none\""
    switch glyph {
    case "text":
        return "<g \(common) stroke-width=\"5\"><path d=\"M37 36h43M37 49h52M37 62h35\"/></g>"
    case "markdown":
        return "<text x=\"64\" y=\"59\" text-anchor=\"middle\" font-family=\"-apple-system,BlinkMacSystemFont,sans-serif\" font-size=\"27\" font-weight=\"800\" fill=\"\(accent)\">M↓</text>"
    case "document":
        return "<g \(common) stroke-width=\"5\"><path d=\"M39 37h35M39 49h46M39 61h28\"/><path d=\"M82 36v27\" opacity=\".32\"/></g>"
    case "table":
        return "<g \(common) stroke-width=\"3.5\"><rect x=\"36\" y=\"34\" width=\"54\" height=\"33\" rx=\"3\"/><path d=\"M36 45h54M36 56h54M54 34v33M72 34v33\"/></g>"
    case "slides":
        return "<g \(common) stroke-width=\"4\"><rect x=\"35\" y=\"33\" width=\"56\" height=\"35\" rx=\"5\"/><path d=\"M47 58l9-10 8 7 11-13 8 16\"/></g>"
    case "image":
        return "<g \(common) stroke-width=\"4\"><rect x=\"34\" y=\"31\" width=\"58\" height=\"39\" rx=\"7\"/><circle cx=\"76\" cy=\"42\" r=\"5\" fill=\"\(accent)\" stroke=\"none\"/><path d=\"M39 64l14-15 10 10 8-8 16 13\"/></g>"
    case "audio":
        return "<g \(common) stroke-width=\"5\"><path d=\"M39 51v-8M49 61V33M59 56V38M69 65V29M79 57V37M89 52V42\"/></g>"
    case "video":
        return "<g \(common) stroke-width=\"4\"><rect x=\"34\" y=\"31\" width=\"58\" height=\"40\" rx=\"8\"/><path d=\"M58 43l15 8-15 9z\" fill=\"\(accent)\" stroke=\"none\"/></g>"
    case "archive":
        return "<g fill=\"\(accent)\"><rect x=\"58\" y=\"29\" width=\"11\" height=\"8\" rx=\"2\"/><rect x=\"58\" y=\"40\" width=\"11\" height=\"8\" rx=\"2\"/><rect x=\"58\" y=\"51\" width=\"11\" height=\"8\" rx=\"2\"/><path d=\"M55 63h17v8H55z\"/></g>"
    case "package":
        return "<g \(common) stroke-width=\"4\"><path d=\"M39 42l25-13 25 13-25 14zM39 42v24l25 13 25-13V42M64 56v23\"/></g>"
    case "font":
        return "<text x=\"64\" y=\"63\" text-anchor=\"middle\" font-family=\"Georgia,serif\" font-size=\"34\" font-weight=\"700\" fill=\"\(accent)\">Aa</text>"
    case "code":
        return "<text x=\"64\" y=\"61\" text-anchor=\"middle\" font-family=\"SFMono-Regular,Menlo,monospace\" font-size=\"25\" font-weight=\"800\" fill=\"\(accent)\">&lt;/&gt;</text>"
    case "config":
        return "<g \(common) stroke-width=\"4\"><path d=\"M38 37h50M38 50h50M38 63h50\"/><circle cx=\"54\" cy=\"37\" r=\"5\" fill=\"white\"/><circle cx=\"75\" cy=\"50\" r=\"5\" fill=\"white\"/><circle cx=\"60\" cy=\"63\" r=\"5\" fill=\"white\"/></g>"
    case "database":
        return "<g \(common) stroke-width=\"4\"><ellipse cx=\"64\" cy=\"35\" rx=\"25\" ry=\"9\"/><path d=\"M39 35v27c0 5 11 9 25 9s25-4 25-9V35M39 49c0 5 11 9 25 9s25-4 25-9\"/></g>"
    case "shell":
        return "<text x=\"64\" y=\"61\" text-anchor=\"middle\" font-family=\"SFMono-Regular,Menlo,monospace\" font-size=\"27\" font-weight=\"800\" fill=\"\(accent)\">&gt;_</text>"
    case "api":
        return "<g \(common) stroke-width=\"4\"><path d=\"M46 39l18 11 18-11M46 39v22l18 10 18-10V39\"/><circle cx=\"46\" cy=\"39\" r=\"5\" fill=\"white\"/><circle cx=\"82\" cy=\"39\" r=\"5\" fill=\"white\"/><circle cx=\"64\" cy=\"71\" r=\"5\" fill=\"white\"/></g>"
    case "diff":
        return "<g \(common) stroke-width=\"4\"><path d=\"M39 39h18M48 30v18M70 39h18M39 61h18M70 61h18\"/></g>"
    case "log":
        return "<g \(common) stroke-width=\"4\"><path d=\"M35 53h10l6-17 10 31 8-22 7 8h16\"/></g>"
    case "lock":
        return "<g \(common) stroke-width=\"4\"><rect x=\"42\" y=\"46\" width=\"44\" height=\"27\" rx=\"6\"/><path d=\"M50 46v-8c0-9 6-14 14-14s14 5 14 14v8\"/><circle cx=\"64\" cy=\"59\" r=\"4\" fill=\"\(accent)\" stroke=\"none\"/></g>"
    case "project":
        return "<g \(common) stroke-width=\"4\"><rect x=\"35\" y=\"32\" width=\"24\" height=\"18\" rx=\"4\"/><rect x=\"69\" y=\"32\" width=\"24\" height=\"18\" rx=\"4\"/><rect x=\"52\" y=\"58\" width=\"24\" height=\"18\" rx=\"4\"/><path d=\"M47 50v4h34v-4M64 54v4\"/></g>"
    case "certificate":
        return "<g \(common) stroke-width=\"4\"><path d=\"M64 27l24 9v15c0 14-10 23-24 28-14-5-24-14-24-28V36z\"/><path d=\"M53 52l8 8 15-17\"/></g>"
    case "binary":
        return "<text x=\"64\" y=\"60\" text-anchor=\"middle\" font-family=\"SFMono-Regular,Menlo,monospace\" font-size=\"23\" font-weight=\"800\" fill=\"\(accent)\">01 10</text>"
    case "diagnostic":
        return "<g \(common) stroke-width=\"4\"><circle cx=\"64\" cy=\"51\" r=\"19\"/><path d=\"M64 22v10M64 70v9M35 51h10M83 51h10M44 31l7 7M77 64l7 7M84 31l-7 7M51 64l-7 7\"/><circle cx=\"64\" cy=\"51\" r=\"6\" fill=\"\(accent)\" stroke=\"none\"/></g>"
    case "web":
        return "<g \(common) stroke-width=\"4\"><circle cx=\"64\" cy=\"51\" r=\"25\"/><path d=\"M39 51h50M64 26c8 7 12 15 12 25S72 69 64 76M64 26c-8 7-12 15-12 25s4 18 12 25\"/></g>"
    case "build":
        return "<g \(common) stroke-width=\"5\"><path d=\"M44 65l27-27M62 31l10-5 10 10-5 10M40 61l-7 12 12-7\"/><path d=\"M65 64h23\" opacity=\".45\"/></g>"
    case "git":
        return "<g \(common) stroke-width=\"4\"><path d=\"M49 31v36M49 42h17c9 0 13 5 13 13v12\"/><circle cx=\"49\" cy=\"29\" r=\"6\" fill=\"white\"/><circle cx=\"49\" cy=\"70\" r=\"6\" fill=\"white\"/><circle cx=\"79\" cy=\"70\" r=\"6\" fill=\"white\"/></g>"
    default:
        return "<g \(common) stroke-width=\"5\"><path d=\"M37 38h46M37 51h46M37 64h32\"/></g>"
    }
}

func iconBody(_ spec: FileIconSpec, idPrefix: String) -> String {
    let fontSize: Int
    switch spec.label.count {
    case 0...3: fontSize = 17
    case 4: fontSize = 14
    case 5: fontSize = 12
    default: fontSize = 10
    }
    let glyph = glyphMarkup(spec.glyph, accent: spec.accent)
    return """
    <defs>
      <linearGradient id="badge-\(idPrefix)" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="\(spec.accent)"/>
        <stop offset="1" stop-color="\(spec.accentEnd)"/>
      </linearGradient>
      <filter id="shadow-\(idPrefix)" x="-20%" y="-20%" width="140%" height="150%">
        <feDropShadow dx="0" dy="4" stdDeviation="5" flood-color="#0F172A" flood-opacity=".18"/>
      </filter>
    </defs>
    <g filter="url(#shadow-\(idPrefix))">
      <path d="M24 8h55l25 25v79c0 5-4 9-9 9H24c-5 0-9-4-9-9V17c0-5 4-9 9-9z" fill="#FFFFFF" stroke="\(spec.accent)" stroke-opacity=".30" stroke-width="2"/>
      <path d="M79 8v19c0 5 4 9 9 9h16" fill="\(spec.accent)" fill-opacity=".13" stroke="\(spec.accent)" stroke-opacity=".28" stroke-width="2" stroke-linejoin="round"/>
      \(glyph)
      <rect x="24" y="82" width="71" height="27" rx="9" fill="url(#badge-\(idPrefix))"/>
      <text x="59.5" y="101" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="\(fontSize)" font-weight="800" letter-spacing=".3" fill="\(spec.labelForeground)">\(escaped(spec.label))</text>
    </g>
    """
}

func iconSVG(_ spec: FileIconSpec) -> String {
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
      \(iconBody(spec, idPrefix: spec.key))
    </svg>
    """
}

func embeddedIcon(_ spec: FileIconSpec, idPrefix: String, x: Int, y: Int, size: Int) -> String {
    """
    <svg x="\(x)" y="\(y)" width="\(size)" height="\(size)" viewBox="0 0 128 128">
      \(iconBody(spec, idPrefix: idPrefix))
    </svg>
    """
}

func catalogSVG(_ specs: [FileIconSpec]) -> String {
    let columns = 7
    let cellWidth = 164
    let cellHeight = 188
    let margin = 28
    let headerHeight = 118
    let rows = Int(ceil(Double(specs.count) / Double(columns)))
    let width = margin * 2 + columns * cellWidth
    let height = headerHeight + margin + rows * cellHeight
    var cells = ""
    for (index, spec) in specs.enumerated() {
        let column = index % columns
        let row = index / columns
        let x = margin + column * cellWidth
        let y = headerHeight + row * cellHeight
        cells += """
          <g transform="translate(\(x) \(y))">
            <rect x="4" y="3" width="148" height="174" rx="20" fill="#FFFFFF" stroke="#E2E8F0"/>
            \(embeddedIcon(spec, idPrefix: "catalog-\(spec.key)", x: 23, y: 10, size: 110))
            <text x="78" y="139" text-anchor="middle" class="title">\(escaped(spec.title))</text>
            <text x="78" y="160" text-anchor="middle" class="examples">\(escaped(spec.examples))</text>
          </g>
        """
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
      <rect width="\(width)" height="\(height)" fill="#F8FAFC"/>
      <style>
        .heading { font: 700 28px -apple-system, BlinkMacSystemFont, sans-serif; fill: #0F172A; }
        .subheading { font: 400 15px -apple-system, BlinkMacSystemFont, sans-serif; fill: #64748B; }
        .title { font: 650 14px -apple-system, BlinkMacSystemFont, sans-serif; fill: #1E293B; }
        .examples { font: 400 9px -apple-system, BlinkMacSystemFont, sans-serif; fill: #64748B; }
      </style>
      <text x="\(margin + 4)" y="48" class="heading">Pasteory 文件图标系统</text>
      <text x="\(margin + 4)" y="78" class="subheading">后缀决定标签，文件家族决定图形与颜色；图片只有在文件本身是图片时才显示真实缩略图。</text>
      <text x="\(margin + 4)" y="101" class="subheading">设计稿为 128 × 128 矢量图标，重点检查 32–48 pt 下的标签识别度。</text>
      \(cells)
    </svg>
    """
}

func sizePreviewSVG(_ specs: [FileIconSpec]) -> String {
    let selectedKeys = ["txt", "pdf", "archive", "swift", "xcode", "kotlin", "android-package", "diagnostic", "arkts", "harmony-package", "certificate", "git"]
    let selected = selectedKeys.compactMap { key in specs.first { $0.key == key } }
    let width = 1120
    let height = 500
    let left = 34
    let top = 104
    let columnWidth = 86
    var light48 = ""
    var light32 = ""
    var dark48 = ""
    var dark32 = ""
    for (index, spec) in selected.enumerated() {
        let x = left + index * columnWidth
        let label = escaped(spec.label)
        light48 += embeddedIcon(spec, idPrefix: "size-light48-\(spec.key)", x: x + 8, y: top, size: 48) + "<text x=\"\(x + 32)\" y=\"\(top + 66)\" text-anchor=\"middle\" class=\"lightLabel\">\(label)</text>"
        light32 += embeddedIcon(spec, idPrefix: "size-light32-\(spec.key)", x: x + 16, y: top + 92, size: 32) + "<text x=\"\(x + 32)\" y=\"\(top + 141)\" text-anchor=\"middle\" class=\"lightLabel\">\(label)</text>"
        dark48 += embeddedIcon(spec, idPrefix: "size-dark48-\(spec.key)", x: x + 8, y: top + 208, size: 48) + "<text x=\"\(x + 32)\" y=\"\(top + 274)\" text-anchor=\"middle\" class=\"darkLabel\">\(label)</text>"
        dark32 += embeddedIcon(spec, idPrefix: "size-dark32-\(spec.key)", x: x + 16, y: top + 300, size: 32) + "<text x=\"\(x + 32)\" y=\"\(top + 349)\" text-anchor=\"middle\" class=\"darkLabel\">\(label)</text>"
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
      <style>
        .heading { font: 700 25px -apple-system, BlinkMacSystemFont, sans-serif; fill: #0F172A; }
        .caption { font: 500 13px -apple-system, BlinkMacSystemFont, sans-serif; fill: #64748B; }
        .lightLabel { font: 650 10px -apple-system, BlinkMacSystemFont, sans-serif; fill: #475569; }
        .darkLabel { font: 650 10px -apple-system, BlinkMacSystemFont, sans-serif; fill: #CBD5E1; }
      </style>
      <rect width="\(width)" height="\(height)" fill="#F8FAFC"/>
      <text x="34" y="43" class="heading">32 pt / 48 pt 小尺寸检查</text>
      <text x="34" y="70" class="caption">上半部分为浅色背景，下半部分为深色背景。小尺寸优先保证家族颜色、主图形和短标签可辨认。</text>
      <rect x="20" y="84" width="1080" height="184" rx="22" fill="#FFFFFF" stroke="#E2E8F0"/>
      <text x="1063" y="109" text-anchor="end" class="caption">48 pt</text>
      <text x="1063" y="201" text-anchor="end" class="caption">32 pt</text>
      \(light48)
      \(light32)
      <rect x="20" y="288" width="1080" height="190" rx="22" fill="#111827" stroke="#334155"/>
      <text x="1063" y="313" text-anchor="end" class="darkLabel">48 pt</text>
      <text x="1063" y="405" text-anchor="end" class="darkLabel">32 pt</text>
      \(dark48)
      \(dark32)
    </svg>
    """
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let outputDirectory = projectRoot.appendingPathComponent("docs/file-icons", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for spec in specs {
    try Data(iconSVG(spec).utf8).write(to: outputDirectory.appendingPathComponent("\(spec.key).svg"), options: .atomic)
}
try Data(catalogSVG(specs).utf8).write(to: outputDirectory.appendingPathComponent("catalog.svg"), options: .atomic)
try Data(sizePreviewSVG(specs).utf8).write(to: outputDirectory.appendingPathComponent("size-preview.svg"), options: .atomic)
print("generated_file_icons=\(specs.count)")
print("catalog=\(outputDirectory.appendingPathComponent("catalog.svg").path)")

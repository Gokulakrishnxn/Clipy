import AppKit
import Foundation

/// Offline "smart assistant": pure heuristics, no AI, no network, no API key.
///
/// `SmartDetector.analyze(_:)` looks at a clip's text and returns what it is
/// (a badge for the row) plus the one-key actions that make sense for it
/// (open a link, strip tracking parameters, pretty-print JSON, evaluate
/// `12*7`, convert case, …). Everything runs synchronously in microseconds.
struct SmartInfo {
    var badge: SmartBadge?
    var actions: [SmartAction] = []
    /// Short facts for the action bar, e.g. "12 words · 64 chars".
    var stats: String?
}

struct SmartBadge: Equatable {
    enum Tone { case neutral, info, success, warning, danger }
    let text: String
    let symbol: String?
    let tone: Tone
}

struct SmartAction: Identifiable {
    enum Effect {
        /// Put this text on the clipboard (and paste, per preferences).
        case text(String)
        case open(URL)
        case reveal([URL])
        case saveImage
        case delete
    }

    let id: String
    let title: String
    let symbol: String
    let effect: Effect
}

enum SmartDetector {
    // MARK: Entry point

    static func analyze(_ raw: String) -> SmartInfo {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return SmartInfo() }

        var info = SmartInfo()
        let singleLine = !text.contains("\n")

        if let secret = secretKind(text) {
            info.badge = SmartBadge(text: secret, symbol: "key.fill", tone: .danger)
            info.actions.append(SmartAction(id: "forget", title: "Forget secret", symbol: "trash", effect: .delete))
            return info
        } else if singleLine, let url = webURL(text) {
            return analyzeLink(url, original: text)
        } else if singleLine, isEmail(text) {
            info.badge = SmartBadge(text: "Email", symbol: "envelope", tone: .info)
            if let mail = URL(string: "mailto:\(text)") {
                info.actions.append(SmartAction(id: "mail", title: "Compose", symbol: "square.and.pencil", effect: .open(mail)))
            }
            if let at = text.firstIndex(of: "@") {
                info.actions.append(SmartAction(id: "domain", title: "Copy domain", symbol: "at", effect: .text(String(text[text.index(after: at)...]))))
            }
        } else if singleLine, let rgb = hexColor(text) {
            info.badge = SmartBadge(text: "Color", symbol: "paintpalette", tone: .info)
            info.actions.append(SmartAction(id: "rgb", title: "Copy as rgb()", symbol: "eyedropper", effect: .text(rgb)))
        } else if let pretty = prettyJSON(text) {
            info.badge = SmartBadge(text: "JSON", symbol: "curlybraces", tone: .info)
            info.actions.append(SmartAction(id: "json.pretty", title: "Pretty JSON", symbol: "text.alignleft", effect: .text(pretty.pretty)))
            info.actions.append(SmartAction(id: "json.min", title: "Minify JSON", symbol: "arrow.down.right.and.arrow.up.left", effect: .text(pretty.minified)))
        } else if singleLine, let value = MathEvaluator.evaluate(text) {
            let result = MathEvaluator.format(value)
            info.badge = SmartBadge(text: "= \(result)", symbol: "function", tone: .success)
            info.actions.append(SmartAction(id: "math", title: "Copy result \(result)", symbol: "equal", effect: .text(result)))
        } else if singleLine, let path = filePath(text) {
            info.badge = SmartBadge(text: "Path", symbol: "folder", tone: .neutral)
            info.actions.append(SmartAction(id: "reveal", title: "Reveal in Finder", symbol: "folder", effect: .reveal([path])))
            info.actions.append(SmartAction(id: "openpath", title: "Open", symbol: "arrow.up.forward.app", effect: .open(path)))
        } else if let risk = riskyCommand(text) {
            info.badge = SmartBadge(text: risk, symbol: "exclamationmark.triangle.fill", tone: .warning)
        } else if singleLine, isShellCommand(text) {
            info.badge = SmartBadge(text: "Command", symbol: "terminal", tone: .neutral)
        }

        if info.badge == nil, base64Decoded(text) != nil {
            info.badge = SmartBadge(text: "Base64", symbol: "lock", tone: .neutral)
        }
        // Case conversions only make sense for prose, not commands/JSON/paths.
        info.actions += textTransforms(text, raw: raw, prose: info.badge == nil)
        info.stats = stats(text)
        return info
    }

    // MARK: Links

    /// Query parameters that only track you; removed by "Clean link".
    private static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "igsh",
        "jplx", "si", "ref_src", "ref_url", "_hsenc", "_hsmi", "yclid", "spm", "share_id",
    ]
    /// Query parameters that look like credentials.
    private static let secretParams: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "api_key", "apikey", "key",
        "secret", "password", "pwd", "auth", "sig", "signature", "code", "session",
    ]

    static func webURL(_ text: String) -> URL? {
        guard !text.contains(" ") else { return nil }
        var candidate = text
        if candidate.lowercased().hasPrefix("www.") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".") || host == "localhost" || isIP(host)
        else { return nil }
        return url
    }

    private static func analyzeLink(_ url: URL, original: String) -> SmartInfo {
        var info = SmartInfo()
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let names = (comps?.queryItems ?? []).map { $0.name.lowercased() }
        let hasSecret = names.contains { secretParams.contains($0) }
        let hasTracking = names.contains { trackingParams.contains($0) || $0.hasPrefix("utm_") }
        let isLocal = host == "localhost" || isIP(host)
        let gitHost = ["github.com", "gitlab.com", "bitbucket.org"].contains(host)
        let pathParts = url.pathComponents.filter { $0 != "/" }
        // "Repo" only for the repository itself (owner/name or *.git); deeper
        // pages (releases, issues, files) still get a git clone action.
        let isRepoRoot = original.hasSuffix(".git") || (gitHost && pathParts.count == 2)
        let isGit = isRepoRoot || (gitHost && pathParts.count >= 2)

        if hasSecret {
            info.badge = SmartBadge(text: "Token", symbol: "key.fill", tone: .danger)
        } else if isRepoRoot {
            info.badge = SmartBadge(text: "Repo", symbol: "chevron.left.forwardslash.chevron.right", tone: .info)
        } else if isLocal {
            info.badge = SmartBadge(text: "Local", symbol: "desktopcomputer", tone: .neutral)
        } else if hasTracking {
            info.badge = SmartBadge(text: "Tracked", symbol: "eye", tone: .warning)
        }

        info.actions.append(SmartAction(id: "open", title: "Open", symbol: "safari", effect: .open(url)))
        if hasTracking || hasSecret, var c = comps {
            c.queryItems = c.queryItems?.filter {
                let n = $0.name.lowercased()
                return !trackingParams.contains(n) && !n.hasPrefix("utm_") && !secretParams.contains(n)
            }
            if c.queryItems?.isEmpty == true { c.queryItems = nil }
            if let clean = c.url?.absoluteString {
                info.actions.append(SmartAction(
                    id: "clean", title: hasSecret ? "Copy without token" : "Clean link",
                    symbol: "wand.and.stars", effect: .text(clean)
                ))
            }
        }
        if isGit {
            var repo = original
            if !repo.hasSuffix(".git") {
                let parts = url.pathComponents.filter { $0 != "/" }.prefix(2)
                repo = "https://\(url.host ?? host)/\(parts.joined(separator: "/")).git"
            }
            info.actions.append(SmartAction(id: "clone", title: "git clone", symbol: "terminal", effect: .text("git clone \(repo)")))
        }
        let label = url.pathComponents.filter { $0 != "/" }.last.map { "\(host)/\($0)" } ?? host
        info.actions.append(SmartAction(id: "md", title: "Markdown link", symbol: "link", effect: .text("[\(label)](\(original))")))
        info.actions.append(SmartAction(id: "domain", title: "Copy domain", symbol: "globe", effect: .text(host)))
        return info
    }

    /// "github.com" + "/Gokulakrishnxn/Clipy.git" for the row title.
    static func linkParts(_ text: String) -> (host: String, rest: String)? {
        guard let url = webURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var host = url.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let port = url.port { host += ":\(port)" }
        var rest = url.path == "/" ? "" : url.path
        if let q = url.query, !q.isEmpty { rest += "?" + q }
        return (host, rest)
    }

    // MARK: Classifiers

    private static func isIP(_ host: String) -> Bool {
        host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hexColor(_ s: String) -> String? {
        guard s.range(of: #"^#([0-9a-f]{3}|[0-9a-f]{6})$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        var hex = String(s.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(hex, radix: 16) else { return nil }
        return "rgb(\((v >> 16) & 0xFF), \((v >> 8) & 0xFF), \(v & 0xFF))"
    }

    private static func prettyJSON(_ s: String) -> (pretty: String, minified: String)? {
        guard let first = s.first, first == "{" || first == "[", s.count < 2_000_000,
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let p = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let m = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        else { return nil }
        return (String(decoding: p, as: UTF8.self), String(decoding: m, as: UTF8.self))
    }

    private static func filePath(_ s: String) -> URL? {
        guard s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("file://") else { return nil }
        let url: URL
        if s.hasPrefix("file://") {
            guard let u = URL(string: s) else { return nil }
            url = u
        } else {
            url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func riskyCommand(_ s: String) -> String? {
        let l = s.lowercased()
        let patterns: [(String, String)] = [
            (#"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r)\b"#, "Deletes files"),
            (#"\bmkfs(\.|\s)"#, "Formats disk"),
            (#"\bdd\s+if="#, "Raw disk write"),
            (#":\(\)\s*\{\s*:\|:&\s*\};:"#, "Fork bomb"),
            (#"\bchmod\s+-r\s+777\b"#, "Opens permissions"),
            (#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "Runs remote script"),
            (#"\bgit\s+push\b.*--force\b"#, "Force push"),
            (#"\bdrop\s+(table|database)\b"#, "Drops data"),
        ]
        for (pattern, label) in patterns where l.range(of: pattern, options: .regularExpression) != nil {
            return label
        }
        return nil
    }

    private static let commandWords: Set<String> = [
        "git", "npm", "npx", "pnpm", "yarn", "bun", "brew", "cd", "ls", "cat", "curl", "wget", "ssh",
        "scp", "docker", "kubectl", "python", "python3", "pip", "pip3", "node", "cargo", "swift",
        "xcodebuild", "make", "sudo", "claude", "gh", "open", "echo", "export", "mkdir", "cp", "mv",
        "rm", "chmod", "chown", "grep", "find", "tar", "unzip", "go", "deno", "vercel", "wrangler",
    ]

    private static func isShellCommand(_ s: String) -> Bool {
        var t = s
        if t.hasPrefix("$ ") { t.removeFirst(2) }
        guard let first = t.split(separator: " ").first else { return false }
        return commandWords.contains(String(first)) && t.count < 400
    }

    /// API keys, tokens and private keys copied by accident.
    private static func secretKind(_ s: String) -> String? {
        let patterns: [(String, String)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "Private key"),
            (#"\bsk-(ant-|proj-)?[A-Za-z0-9_-]{20,}"#, "API key"),
            (#"\bgh[pousr]_[A-Za-z0-9]{30,}"#, "GitHub token"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "AWS key"),
            (#"\bxox[baprs]-[A-Za-z0-9-]{10,}"#, "Slack token"),
            (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, "JWT"),
        ]
        for (pattern, label) in patterns where s.range(of: pattern, options: .regularExpression) != nil {
            return label
        }
        return nil
    }

    // MARK: Text transforms

    private static func textTransforms(_ text: String, raw: String, prose: Bool) -> [SmartAction] {
        var out: [SmartAction] = []
        let lines = text.components(separatedBy: .newlines)
        let letters = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }

        if raw != text || text.range(of: #"[ \t]{2,}"#, options: .regularExpression) != nil {
            let collapsed = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            out.append(SmartAction(id: "trim", title: "Trim spaces", symbol: "scissors", effect: .text(collapsed)))
        }
        if lines.count > 1 {
            let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            out.append(SmartAction(id: "join", title: "Join lines", symbol: "arrow.right.to.line", effect: .text(joined)))
            let sorted = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if sorted != lines {
                out.append(SmartAction(id: "sort", title: "Sort lines", symbol: "arrow.up.arrow.down", effect: .text(sorted.joined(separator: "\n"))))
            }
            var seen = Set<String>()
            let unique = lines.filter { seen.insert($0).inserted }
            if unique.count < lines.count {
                out.append(SmartAction(id: "dedupe", title: "Remove duplicates", symbol: "line.3.horizontal.decrease", effect: .text(unique.joined(separator: "\n"))))
            }
        }
        if prose, letters, text.count < 100_000 {
            if text != text.uppercased() {
                out.append(SmartAction(id: "upper", title: "UPPERCASE", symbol: "textformat.size.larger", effect: .text(text.uppercased())))
            }
            if text != text.lowercased() {
                out.append(SmartAction(id: "lower", title: "lowercase", symbol: "textformat.size.smaller", effect: .text(text.lowercased())))
            }
            if text.capitalized != text {
                out.append(SmartAction(id: "title", title: "Title Case", symbol: "textformat", effect: .text(text.capitalized)))
            }
            if lines.count == 1, text.count < 120, text.contains(" ") || text.contains("-") {
                let words = text.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }
                if words.count > 1 {
                    out.append(SmartAction(id: "snake", title: "snake_case", symbol: "underline", effect: .text(words.joined(separator: "_"))))
                    let camel = words.first! + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
                    out.append(SmartAction(id: "camel", title: "camelCase", symbol: "character.cursor.ibeam", effect: .text(camel)))
                }
            }
        }
        if text.contains("%"), let decoded = text.removingPercentEncoding, decoded != text {
            out.append(SmartAction(id: "urldecode", title: "URL decode", symbol: "percent", effect: .text(decoded)))
        }
        if let decoded = base64Decoded(text) {
            out.append(SmartAction(id: "b64d", title: "Base64 decode", symbol: "lock.open", effect: .text(decoded)))
        } else if prose, text.count < 50_000 {
            out.append(SmartAction(id: "b64e", title: "Base64 encode", symbol: "lock", effect: .text(Data(text.utf8).base64EncodedString())))
        }
        return out
    }

    private static func base64Decoded(_ s: String) -> String? {
        guard s.count >= 8, s.count % 4 == 0, !s.contains(" "),
              s.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil,
              let data = Data(base64Encoded: s),
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty, str.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
        else { return nil }
        return str
    }

    private static func stats(_ text: String) -> String {
        let words = text.split { $0.isWhitespace }.count
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var parts = ["\(words) word\(words == 1 ? "" : "s")", "\(text.count) chars"]
        if lines > 1 { parts.append("\(lines) lines") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Math

/// A tiny recursive-descent calculator: + − × ÷ % ^, parentheses, unary minus.
/// Deliberately not `NSExpression` (which raises Objective-C exceptions on bad
/// input and accepts function calls).
enum MathEvaluator {
    static func evaluate(_ input: String) -> Double? {
        let s = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard s.count <= 200,
              s.range(of: #"^[0-9+\-*/%^(). ]+$"#, options: .regularExpression) != nil,
              s.range(of: #"[0-9]"#, options: .regularExpression) != nil,
              // Needs an operator between operands, not just "-5" or "3.14".
              s.dropFirst().contains(where: { "+-*/%^".contains($0) })
        else { return nil }
        var p = Parser(chars: Array(s.filter { $0 != " " }))
        guard let v = p.expression(), p.i == p.chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 8
        f.minimumIntegerDigits = 1
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while i < chars.count, "*/%".contains(chars[i]) {
                let op = chars[i]; i += 1
                guard let r = power() else { return nil }
                switch op {
                case "*": v *= r
                case "/": guard r != 0 else { return nil }; v /= r
                default: guard r != 0 else { return nil }; v = v.truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if i < chars.count, chars[i] == "^" {
                i += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func unary() -> Double? {
            if i < chars.count, chars[i] == "-" { i += 1; return unary().map { -$0 } }
            if i < chars.count, chars[i] == "+" { i += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            if i < chars.count, chars[i] == "(" {
                i += 1
                guard let v = expression(), i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            guard i > start else { return nil }
            return Double(String(chars[start..<i]))
        }
    }
}

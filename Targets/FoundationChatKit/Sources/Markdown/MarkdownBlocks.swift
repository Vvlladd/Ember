import Foundation

/// A parsed block of assistant markdown: prose or a fenced code block.
public enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case code(language: String?, code: String)
}

/// Splits text into prose and fenced ``` ``` ``` code blocks. An unterminated fence (as happens
/// mid-stream) is treated as a trailing code block. Pure and fully testable.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false
        var lang: String?

        func flushProse() {
            let joined = prose.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.prose(joined))
            }
            prose = []
        }
        func flushCode() {
            blocks.append(.code(language: lang, code: code.joined(separator: "\n")))
            code = []; lang = nil
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    flushCode(); inCode = false
                } else {
                    flushProse(); inCode = true
                    let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    lang = tag.isEmpty ? nil : tag
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return blocks
    }
}

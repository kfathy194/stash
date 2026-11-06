import Foundation

public enum CodeLanguage: String, CaseIterable, Sendable {
    case css, html, php, javascript, typescript, json, markdown, sql, python, swift, bash, yaml, xml

    public var label: String {
        switch self {
        case .css: "CSS"
        case .html: "HTML"
        case .php: "PHP"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .sql: "SQL"
        case .python: "Python"
        case .swift: "Swift"
        case .bash: "Bash"
        case .yaml: "YAML"
        case .xml: "XML"
        }
    }
}

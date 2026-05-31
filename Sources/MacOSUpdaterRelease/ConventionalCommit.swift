// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public struct ConventionalCommit: Equatable, Sendable {
    public let type: String
    public let scope: String?
    public let summary: String
    public let isBreakingChange: Bool
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let subject = ConventionalCommit.dropLeadingGitHash(from: trimmed)
        guard let colonIndex = subject.firstIndex(of: ":") else {
            return nil
        }

        let header = String(subject[..<colonIndex])
        let summaryStart = subject.index(after: colonIndex)
        let summary = subject[summaryStart...].trimmingCharacters(in: .whitespaces)
        guard !summary.isEmpty else {
            return nil
        }

        let isHeaderBreaking = header.hasSuffix("!")
        let normalizedHeader = isHeaderBreaking ? String(header.dropLast()) : header

        let type: String
        let scope: String?
        if
            let openScope = normalizedHeader.firstIndex(of: "("),
            normalizedHeader.hasSuffix(")")
        {
            type = String(normalizedHeader[..<openScope])
            let scopeStart = normalizedHeader.index(after: openScope)
            scope = String(normalizedHeader[scopeStart..<normalizedHeader.index(before: normalizedHeader.endIndex)])
        } else {
            type = normalizedHeader
            scope = nil
        }

        guard !type.isEmpty, type.allSatisfy({ $0.isLetter || $0 == "-" }) else {
            return nil
        }

        self.type = type
        self.scope = scope
        self.summary = summary
        self.isBreakingChange = isHeaderBreaking || trimmed.contains("BREAKING CHANGE")
        self.rawValue = rawValue
    }

    public var formattedBullet: String {
        if let scope, !scope.isEmpty {
            return "- \(scope): \(summary)"
        }
        return "- \(summary)"
    }

    private static func dropLeadingGitHash(from value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return value
        }
        let possibleHash = parts[0]
        guard possibleHash.count >= 7, possibleHash.allSatisfy(\.isHexDigit) else {
            return value
        }
        return String(parts[1])
    }
}

public struct ChangelogDraftGenerator: Sendable {
    public let includedTypes: Set<String>

    public init(includedTypes: Set<String> = ["feat", "fix", "perf", "security"]) {
        self.includedTypes = includedTypes
    }

    public func generate(version: SemanticVersion, commits rawCommits: [String]) -> String {
        let commits = rawCommits.compactMap(ConventionalCommit.init(rawValue:))
        let included = commits.filter { includedTypes.contains($0.type) || $0.isBreakingChange }

        var sections: [(title: String, commits: [ConventionalCommit])] = [
            ("Breaking Changes", included.filter(\.isBreakingChange)),
            ("Features", included.filter { $0.type == "feat" && !$0.isBreakingChange }),
            ("Fixes", included.filter { $0.type == "fix" && !$0.isBreakingChange }),
            ("Performance", included.filter { $0.type == "perf" && !$0.isBreakingChange }),
            ("Security", included.filter { $0.type == "security" && !$0.isBreakingChange })
        ]
        sections.removeAll { $0.commits.isEmpty }

        var lines = ["## \(version)", ""]
        if sections.isEmpty {
            lines.append("- No user-facing changes in the selected commits.")
        } else {
            for (sectionIndex, section) in sections.enumerated() {
                if sectionIndex > 0 {
                    lines.append("")
                }
                lines.append("### \(section.title)")
                lines.append(contentsOf: section.commits.map(\.formattedBullet))
            }
        }

        return lines.joined(separator: "\n")
    }
}

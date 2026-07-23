//
//  LegalDocumentView.swift
//  YentlShared
//
//  Renders a `LegalDocument` (Terms / Privacy) — a scrollable document with a
//  title, effective date, section headings, bullets, and paragraphs. Shared so
//  onboarding's consent step and Account & Privacy present the same pages.
//

import SwiftUI

public struct LegalDocumentView: View {
    let document: LegalDocument

    public init(document: LegalDocument) {
        self.document = document
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Text(document.title)
                    .font(DesignTokens.Typography.titleLarge)
                Text("Effective \(document.effectiveDate)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block.view
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.lg)
        }
        .navigationTitle(document.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Split the lightweight-markdown body into renderable blocks.
    private var blocks: [Block] {
        document.body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if line.hasPrefix("## ") {
                    return .heading(String(line.dropFirst(3)))
                } else if line.hasPrefix("- ") {
                    return .bullet(String(line.dropFirst(2)))
                } else {
                    return .paragraph(line)
                }
            }
    }

    private enum Block {
        case heading(String)
        case bullet(String)
        case paragraph(String)

        @ViewBuilder var view: some View {
            switch self {
            case .heading(let text):
                Text(text)
                    .font(DesignTokens.Typography.titleMedium)
                    .padding(.top, DesignTokens.Spacing.sm)
            case .bullet(let text):
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                    Text("•")
                    Text(text)
                }
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            case .paragraph(let text):
                Text(text)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
        }
    }
}

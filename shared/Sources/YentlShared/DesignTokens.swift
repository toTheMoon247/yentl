import SwiftUI

/// Cross-app design tokens.
///
/// Placeholders at Phase 0 — both apps import from a single source of
/// truth, but the concrete values get refined once design lands.
public enum DesignTokens {
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    public enum CornerRadius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 20
    }

    /// Cross-platform SwiftUI colors. Adaptive (light/dark) by default.
    /// Replace with brand colors once defined.
    public enum Palette {
        public static let primary = Color.accentColor
        public static let textPrimary = Color.primary
        public static let textSecondary = Color.secondary
    }

    public enum Typography {
        public static let titleLarge = Font.system(size: 34, weight: .bold)
        public static let titleMedium = Font.system(size: 24, weight: .semibold)
        public static let body = Font.system(size: 16, weight: .regular)
        public static let caption = Font.system(size: 13, weight: .regular)
    }
}

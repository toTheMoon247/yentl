import SwiftUI

#if canImport(UIKit)
import UIKit

/// A tiny in-memory image cache so prefetched photos appear instantly (bytes
/// downloaded AND decoded in memory — no network or URLCache revalidation when
/// the view shows). Shared by both iOS apps. UIKit-only, so it's excluded from
/// the package's macOS build (nothing else in the package references it).
@MainActor
public final class ImageCache {
    public static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {}

    public func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Returns the decoded image, downloading + caching it if needed.
    @discardableResult
    public func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Shows an image from `url`, served instantly from the in-memory cache when
/// it's already been prefetched; otherwise loads (and caches) it on appear.
public struct CachedImage<Placeholder: View>: View {
    private let url: URL?
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?

    public init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImageCache.shared.cached(url) {
                image = hit
            } else {
                image = await ImageCache.shared.load(url)
            }
        }
    }
}
#endif

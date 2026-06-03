//
//  CachedImage.swift
//  Yentl
//
//  A tiny in-memory image cache + view, so prefetched discovery photos appear
//  instantly (the bytes are already downloaded AND decoded in memory — no
//  network or URLCache revalidation when the card shows). Lives in the app
//  target because it uses UIKit.
//

import SwiftUI
import UIKit

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {}

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Returns the decoded image, downloading + caching it if needed.
    @discardableResult
    func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Shows an image from `url`, served instantly from the in-memory cache when
/// it's already been prefetched; otherwise loads it (and caches it) on appear.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
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

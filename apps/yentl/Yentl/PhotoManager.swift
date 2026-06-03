//
//  PhotoManager.swift
//  Yentl
//
//  Reusable photo-management section (add / reorder / delete) used by both the
//  profile creation wizard and the edit screen. Renders Form `Section`s, so the
//  parent must embed it inside a `Form`, and provide an `EditButton` (in a
//  toolbar) to enable drag-to-reorder. Uploads/deletes/reorders persist
//  immediately via ProfileService. `photoCount` is written back so parents can
//  gate actions (e.g. require at least one photo).
//

import PhotosUI
import SwiftUI
import UIKit
import YentlShared

struct PhotoManager: View {
    @Binding var photoCount: Int

    @Environment(ProfileService.self) private var profiles

    @State private var photos: [ProfilePhoto] = []
    @State private var urls: [UUID: URL] = [:]
    @State private var picked: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var isUploading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            Section {
                PhotosPicker(
                    selection: $picked,
                    maxSelectionCount: 6,
                    matching: .images
                ) {
                    Label("Add photos", systemImage: "photo.badge.plus")
                }
                .disabled(isUploading)
                if isUploading {
                    HStack { ProgressView(); Text("Uploading…") }
                }
            } footer: {
                Text("Add at least one photo. Drag to reorder, swipe to delete.")
            }

            Section("Your photos") {
                if photos.isEmpty && !isLoading {
                    Text("No photos yet.")
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
                ForEach(photos) { photo in
                    PhotoRow(url: urls[photo.id])
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .task { await load() }
        .onChange(of: picked) { _, items in
            Task { await upload(items) }
        }
        .onChange(of: photos) { _, new in
            photoCount = new.count
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await profiles.listPhotos()
            for photo in photos where urls[photo.id] == nil {
                urls[photo.id] = try? await profiles.signedPhotoURL(for: photo.storagePath)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        errorMessage = nil
        isUploading = true
        defer { isUploading = false; picked = [] }
        do {
            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let jpeg = ImageDownscaler.jpeg(from: data) else { continue }
                try await profiles.uploadPhoto(jpegData: jpeg)
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { photos[$0] }
        Task {
            errorMessage = nil
            do {
                for photo in targets {
                    try await profiles.deletePhoto(photo)
                    urls[photo.id] = nil
                }
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        photos.move(fromOffsets: offsets, toOffset: destination)
        let reordered = photos
        Task {
            do { try await profiles.reorderPhotos(reordered) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct PhotoRow: View {
    let url: URL?

    var body: some View {
        HStack {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm))
            } else {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm)
                    .fill(.quaternary)
                    .frame(width: 56, height: 56)
                    .overlay(ProgressView())
            }
            Text("Photo")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
    }
}

/// Downscales arbitrary image data to a reasonably-sized JPEG for upload.
/// Lives in the app target (UIKit isn't available in the shared package,
/// which also builds for macOS).
enum ImageDownscaler {
    static func jpeg(from data: Data, maxDimension: CGFloat = 1200, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longest)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

//
//  SwipeCard.swift
//  Yentl
//
//  A draggable discovery card: photo + name/age/location. Drag right to like,
//  left to pass (with a LIKE/PASS overlay that fades in with the drag); tap to
//  open the full profile. Pass/Like buttons in DiscoveryView do the same thing
//  for people who'd rather not drag.
//

import SwiftUI
import YentlShared

struct SwipeCard: View {
    let profile: Profile
    let photoURL: URL?
    let onSwipe: (SwipeAction) -> Void
    let onTap: () -> Void

    @State private var offset: CGSize = .zero

    private let threshold: CGFloat = 120

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            photo
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            info
            overlays
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.lg))
        .shadow(radius: 6, y: 3)
        .offset(offset)
        .rotationEffect(.degrees(Double(offset.width / 22)))
        .gesture(drag)
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var photo: some View {
        if let photoURL {
            CachedImage(url: photoURL) {
                placeholder.overlay(ProgressView())
            }
        } else {
            placeholder.overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white.opacity(0.7))
            )
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [.pink.opacity(0.5), .purple.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(nameAndAge)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Label(profile.location, systemImage: "mappin.and.ellipse")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private var overlays: some View {
        ZStack {
            stampLabel("LIKE", color: .green, rotation: -18, alignment: .topLeading)
                .opacity(Double(max(0, offset.width) / threshold))
            stampLabel("PASS", color: .red, rotation: 18, alignment: .topTrailing)
                .opacity(Double(max(0, -offset.width) / threshold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(DesignTokens.Spacing.lg)
    }

    private func stampLabel(
        _ text: String,
        color: Color,
        rotation: Double,
        alignment: Alignment
    ) -> some View {
        Text(text)
            .font(.system(size: 32, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm)
                    .stroke(color, lineWidth: 4)
            )
            .rotationEffect(.degrees(rotation))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var nameAndAge: String {
        if let age = profile.age { return "\(profile.displayName), \(age)" }
        return profile.displayName
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { offset = $0.translation }
            .onEnded { value in
                if value.translation.width > threshold {
                    commit(.like, toX: 700)
                } else if value.translation.width < -threshold {
                    commit(.pass, toX: -700)
                } else {
                    withAnimation(.spring) { offset = .zero }
                }
            }
    }

    private func commit(_ action: SwipeAction, toX: CGFloat) {
        withAnimation(.easeOut(duration: 0.25)) {
            offset = CGSize(width: toX, height: offset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onSwipe(action)
        }
    }
}

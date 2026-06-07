//
//  YentlApp.swift
//  Yentl
//

import SwiftUI
import YentlShared

@main
struct YentlApp: App {
    @State private var auth = AuthService.shared
    @State private var profiles = ProfileService.shared
    @State private var discovery = DiscoveryService.shared
    @State private var matches = MatchService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(profiles)
                .environment(discovery)
                .environment(matches)
        }
    }
}

//
//  YentlMatchmakerApp.swift
//  YentlMatchmaker
//

import SwiftUI
import YentlShared

@main
struct YentlMatchmakerApp: App {
    @State private var auth = AuthService.shared
    @State private var profiles = ProfileService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(profiles)
        }
    }
}

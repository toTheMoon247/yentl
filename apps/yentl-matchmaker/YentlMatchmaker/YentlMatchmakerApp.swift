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
    @State private var matchmaker = MatchmakerService.shared
    @State private var matches = MatchService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(profiles)
                .environment(matchmaker)
                .environment(matches)
        }
    }
}

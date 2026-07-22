//
//  YentlApp.swift
//  Yentl
//

import OneSignalFramework
import SwiftUI
import YentlShared

@main
struct YentlApp: App {
    @State private var auth = AuthService.shared
    @State private var profiles = ProfileService.shared
    @State private var discovery = DiscoveryService.shared
    @State private var matches = MatchService.shared
    @State private var chat = ChatService.shared

    init() {
        // Verbose SDK logging in DEBUG only — release builds stay quiet.
        #if DEBUG
        OneSignal.Debug.setLogLevel(.LL_VERBOSE)
        #endif
        OneSignal.initialize(AppEnvironment.current.oneSignalAppID, withLaunchOptions: nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(profiles)
                .environment(discovery)
                .environment(matches)
                .environment(chat)
        }
    }
}

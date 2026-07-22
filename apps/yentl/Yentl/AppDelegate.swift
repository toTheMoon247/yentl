//
//  AppDelegate.swift
//  Yentl
//
//  Phase 8: minimal UIKit app delegate whose only job is to capture the raw
//  APNs device token so ChatService can register it with Stream Chat push.
//
//  Coexistence with OneSignal (verified against the OneSignal 5.x source,
//  OneSignalNotifications/Categories/UIApplicationDelegate+OneSignalNotifications.m):
//  OneSignal swizzles application(_:didRegisterForRemoteNotificationsWithDeviceToken:),
//  consumes the token via OSNotificationsManager.processRegisteredDeviceToken,
//  and then *forwards to the original implementation* through its
//  SwizzlingForwarder — so this callback still fires with OneSignal installed,
//  and both SDKs see the same token. OneSignal also triggers
//  registerForRemoteNotifications() itself, so nobody needs to call it here.
//
//  Phase 8 (device test): APNs never delivers to the simulator, so the full
//  chain (token → Stream registration → push arrives while OneSignal pushes
//  still work) can only be proven on a physical device with the paid Apple
//  Developer account active. Until then this is reviewed-but-unproven.
//

import OSLog
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let logger = Logger(subsystem: "com.yentl.app", category: "push")

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.logger.info("APNs device token received (\(deviceToken.count) bytes) — handing to ChatService for Stream registration")
        Task { @MainActor in
            ChatService.shared.apnsDeviceTokenReceived(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on the simulator and on devices without an APNs entitlement.
        // Best-effort: chat itself is unaffected, only chat pushes are.
        Self.logger.warning("APNs registration failed: \(String(describing: error))")
    }
}

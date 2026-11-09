//
//  SceneDelegate.swift
//  BilibiliLive
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        // Explicitly match the scene coordinate space; on physical tvOS a window
        // initialized without a frame can retain a half-size center and crop UI.
        window.frame = windowScene.coordinateSpace.bounds
        self.window = window

        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--family-preview") {
            if ProcessInfo.processInfo.arguments.contains("--family-probe-clock-recovery")
                || ProcessInfo.processInfo.arguments.contains("--family-probe-quiz-resume")
                || ProcessInfo.processInfo.arguments.contains("--family-probe-rest-status")
                || ProcessInfo.processInfo.arguments.contains("--family-probe-schedule-status") {
                window.rootViewController = FamilyClockRecoveryProbeHost()
            } else if ProcessInfo.processInfo.arguments.contains("--family-probe-clock") {
                window.rootViewController = FamilyClockPlaybackProbeController()
            } else if ProcessInfo.processInfo.arguments.contains("--family-probe-adult") {
                window.rootViewController = FamilyAdultProbeController()
            } else if ProcessInfo.processInfo.arguments.contains("--family-probe-media")
                || ProcessInfo.processInfo.arguments.contains("--family-probe-quiz") {
                window.rootViewController = FamilyPlaybackProbeController()
            } else {
                window.rootViewController = FamilyControlViewController()
            }
            window.makeKeyAndVisible()
            return
        }
        #endif

        if ApiRequest.isLogin() {
            if let expireDate = ApiRequest.getToken()?.expireDate {
                let now = Date()
                if expireDate.timeIntervalSince(now) < 60 * 60 * 30 {
                    ApiRequest.refreshToken()
                }
            } else {
                ApiRequest.refreshToken()
            }
            window.rootViewController = BLTabBarViewController()
        } else {
            window.rootViewController = LoginViewController.create()
        }
        window.makeKeyAndVisible()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        PlaybackCoordinator.shared.suspend(reason: "scene inactive")
        Task { await FamilyEnvironment.shared.auth.revokeAuthorizations() }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        PlaybackCoordinator.shared.suspend(reason: "scene background")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Task { await FamilyEnvironment.shared.refresh() }
    }

    func showLogin() {
        replaceRootViewController(with: LoginViewController.create(), animated: false)
    }

    func showTabBar() {
        replaceRootViewController(with: BLTabBarViewController(), animated: false)
    }

    func resetTabBar() {
        replaceRootViewController(with: BLTabBarViewController(), animated: true)
    }

    private func replaceRootViewController(with viewController: UIViewController, animated: Bool) {
        PlaybackCoordinator.shared.suspend(reason: "root controller replacement")
        Task { await FamilyEnvironment.shared.auth.revokeAuthorizations() }
        guard let window else { return }
        if animated, let snapshot = window.snapshotView(afterScreenUpdates: false) {
            window.rootViewController = viewController
            window.makeKeyAndVisible()
            viewController.view.addSubview(snapshot)
            UIView.animate(withDuration: 0.25, animations: {
                snapshot.alpha = 0
            }, completion: { _ in
                snapshot.removeFromSuperview()
            })
        } else {
            window.rootViewController = viewController
            window.makeKeyAndVisible()
        }
    }
}

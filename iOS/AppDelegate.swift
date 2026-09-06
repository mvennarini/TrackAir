import UIKit
import SwiftUI
import Combine

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        (window?.rootViewController as? OrientationAware)?.currentOrientations ?? .portrait
    }
}

protocol OrientationAware: AnyObject { var currentOrientations: UIInterfaceOrientationMask { get } }

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let client = Client()
    let settings = Settings()
    private var bag = Set<AnyCancellable>()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let root = ContentView().environmentObject(client).environmentObject(settings)
        let w = UIWindow(windowScene: ws)
        let host = HostingController(rootView: root)
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
        // Abbinamento e ricerca in verticale; trackpad in orizzontale.
        client.$state
            .map { if case .connected = $0 { return true } else { return false } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak host] connected in
                host?.portrait = !connected
                host?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            .store(in: &bag)
        UIApplication.shared.isIdleTimerDisabled = true
        client.startBrowsing()
        // I gesti di editing di iOS (3 dita = annulla/ripeti/copia) stanno sulla
        // finestra: li spengo, subito e dopo che iOS li ha eventualmente aggiunti.
        disableSystemGestures()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.disableSystemGestures() }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        disableSystemGestures()
        if !client.isConnected { client.startBrowsing() }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        client.stop()   // niente traffico in background, la sessione riparte al ritorno
    }

    private func disableSystemGestures() {
        window?.gestureRecognizers?.forEach { $0.isEnabled = false }
        window?.rootViewController?.view.gestureRecognizers?.forEach { $0.isEnabled = false }
    }
}

/// Controller radice: solo orizzontale, senza i gesti di editing di iOS
/// (scorri a 3 dita = annulla/ripeti, tap a 3 dita = menu) che rubavano i tocchi.
final class HostingController<Content: View>: UIHostingController<Content>, OrientationAware {
    var portrait = true
    var currentOrientations: UIInterfaceOrientationMask { portrait ? .portrait : .landscape }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { currentOrientations }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
}

import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    // Flutter forwards these callbacks to both Google Sign-In and app_links.
    super.scene(scene, openURLContexts: URLContexts)
  }
}

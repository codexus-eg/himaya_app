import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // نفس مفتاح الخرائط المستخدم على أندرويد (غير مقيَّد بتطبيق، فيعمل على المنصتين).
    // يتطلب تفعيل Maps SDK for iOS في نفس مشروع Google Cloud.
    GMSServices.provideAPIKey("AIzaSyAgbMPs85FD02GMygXb2mjMdwu4vfK1VqU")
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

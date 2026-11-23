import AppTrackingTransparency
import GoogleMobileAds
import SwiftUI
import UIKit
import UserMessagingPlatform

/// AdMob integration.
/// - Consent first: Google's User Messaging Platform shows the GDPR / US-states form where required;
///   ads are requested only when `canRequestAds` is true. Then iOS's tracking prompt (ATT) is shown once.
/// - Banner: anchored adaptive banner above the tab bar on Tasks, Calendar and Mine.
/// - Interstitial: only at natural breaks (after saving a task or a plan), at most once every
///   3 minutes, every 3rd break, never in the first minute. Never on launch, in the widget or on the watch.
/// - Debug builds use Google's test ad units (see project.yml) so testing never counts as invalid traffic.
@MainActor
final class AdsManager: NSObject, ObservableObject, FullScreenContentDelegate {
    static let shared = AdsManager()

    static let minInterval: TimeInterval = 180
    static let everyNth = 3
    static let sessionGrace: TimeInterval = 60

    @Published private(set) var ready = false
    @Published private(set) var privacyOptionsRequired = false

    let bannerUnitID = Bundle.main.object(forInfoDictionaryKey: "AdMobBannerID") as? String ?? ""
    private let interstitialUnitID = Bundle.main.object(forInfoDictionaryKey: "AdMobInterstitialID") as? String ?? ""
    private var interstitial: InterstitialAd?
    private var loading = false
    private var started = false
    private var breaks = 0
    private var lastShown: Date?
    private let sessionStart = Date()

    static var rootViewController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }

    func gatherConsent() {
        if ScreenshotMode.isOn { return } // store screenshots show no ads or prompts
        // Consent from a previous launch lets ads start straight away.
        startIfAllowed()
        ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let vc = Self.rootViewController {
                    ConsentForm.loadAndPresentIfRequired(from: vc) { [weak self] _ in
                        Task { @MainActor in self?.afterConsent() }
                    }
                } else {
                    self.afterConsent()
                }
            }
        }
    }

    private func afterConsent() {
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        startIfAllowed()
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            // Must be asked while the app is active; ads still work if the user declines.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                ATTrackingManager.requestTrackingAuthorization { _ in }
            }
        }
    }

    private func startIfAllowed() {
        guard ConsentInformation.shared.canRequestAds, !started else { return }
        started = true
        MobileAds.shared.start { [weak self] _ in
            Task { @MainActor in
                self?.ready = true
                self?.loadInterstitial()
            }
        }
    }

    func showPrivacyOptions() {
        guard let vc = Self.rootViewController else { return }
        ConsentForm.presentPrivacyOptionsForm(from: vc) { [weak self] _ in
            Task { @MainActor in self?.afterConsent() }
        }
    }

    private func loadInterstitial() {
        guard ready, interstitial == nil, !loading, !interstitialUnitID.isEmpty else { return }
        loading = true
        InterstitialAd.load(with: interstitialUnitID, request: Request()) { [weak self] ad, _ in
            Task { @MainActor in
                guard let self else { return }
                self.loading = false
                self.interstitial = ad
                ad?.fullScreenContentDelegate = self
            }
        }
    }

    /// Call at a natural break; shows an interstitial only when the frequency caps allow.
    func onNaturalBreak() {
        breaks += 1
        let now = Date()
        guard let ad = interstitial, let vc = Self.rootViewController,
              breaks % Self.everyNth == 0,
              now.timeIntervalSince(sessionStart) >= Self.sessionGrace,
              lastShown.map({ now.timeIntervalSince($0) >= Self.minInterval }) ?? true
        else { loadInterstitial(); return }
        lastShown = now
        interstitial = nil
        ad.present(from: vc)
    }

    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in self.loadInterstitial() }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in self.loadInterstitial() }
    }
}

/// Anchored adaptive banner. Renders nothing until consent allows ads.
struct BannerAdView: View {
    @EnvironmentObject private var ads: AdsManager

    var body: some View {
        if ads.ready && !ads.bannerUnitID.isEmpty {
            GeometryReader { geo in
                BannerRepresentable(unitID: ads.bannerUnitID, width: geo.size.width)
                    .frame(width: geo.size.width, height: currentOrientationAnchoredAdaptiveBanner(width: geo.size.width).size.height)
            }
            .frame(height: currentOrientationAnchoredAdaptiveBanner(width: UIScreen.main.bounds.width).size.height)
            .accessibilityLabel("Advertisement")
        }
    }
}

private struct BannerRepresentable: UIViewRepresentable {
    let unitID: String
    let width: CGFloat

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: max(width, 320)))
        banner.adUnitID = unitID
        banner.rootViewController = AdsManager.rootViewController
        banner.load(Request())
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {
        let size = currentOrientationAnchoredAdaptiveBanner(width: max(width, 320))
        if banner.adSize.size.width != size.size.width {
            banner.adSize = size
            banner.load(Request())
        }
    }
}

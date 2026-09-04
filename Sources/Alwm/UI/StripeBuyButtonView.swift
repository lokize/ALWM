import AppKit
import SwiftUI
import WebKit

/// Stripe Buy Button embed for the status menu (publishable key is client-safe by design).
enum StripeBuyButtonConfig {
    static let buyButtonID = "buy_btn_1UBvkHGal1e5K5Xoom1pJGUb"
    /// Payment Link behind the buy button — used by `scripts/sync-donors-from-stripe.sh`.
    static let paymentLinkID = "plink_1UBvk5Gal1e5K5Xo0WxWvwex"
    static let publishableKey =
        "pk_live_51J9zH0Gal1e5K5XoHm4N6z1N5eCtyNsl6efUF09xOG750IoMQCqAhnQ85dGjyIzozh1GPCunZyzAM6uz9rLnfcjy007zJVjcFB"
}

struct StripeBuyButtonView: NSViewRepresentable {
    var onOpenCheckout: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenCheckout: onOpenCheckout)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.clipsToBounds = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://js.stripe.com/"))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onOpenCheckout = onOpenCheckout
    }

    private static var html: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: transparent !important;
              display: flex;
              justify-content: stretch;
              align-items: center;
              min-height: 40px;
              overflow: hidden;
              box-sizing: border-box;
            }
            stripe-buy-button {
              width: 100%;
              display: block;
            }
          </style>
          <script async src="https://js.stripe.com/v3/buy-button.js"></script>
        </head>
        <body>
          <stripe-buy-button
            buy-button-id="\(StripeBuyButtonConfig.buyButtonID)"
            publishable-key="\(StripeBuyButtonConfig.publishableKey)">
          </stripe-buy-button>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onOpenCheckout: (() -> Void)?

        init(onOpenCheckout: (() -> Void)?) {
            self.onOpenCheckout = onOpenCheckout
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if Self.shouldOpenExternally(url) {
                NSWorkspace.shared.open(url)
                onOpenCheckout?()
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                if Self.shouldOpenExternally(url) || navigationAction.targetFrame == nil {
                    NSWorkspace.shared.open(url)
                    onOpenCheckout?()
                }
            }
            return nil
        }

        private static func shouldOpenExternally(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return host.contains("checkout.stripe.com")
                || host.contains("billing.stripe.com")
                || host.contains("buy.stripe.com")
                || host.contains("invoice.stripe.com")
        }
    }
}

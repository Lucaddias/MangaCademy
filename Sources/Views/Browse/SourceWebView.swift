import SwiftUI
import WebKit

/// Abre o site da fonte numa WebView com o mesmo User-Agent do app. O usuário passa pela
/// verificação do Cloudflare (ou faz login) e os cookies vão para as requisições do app.
struct SourceWebView: View {
    let title: String
    let url: URL
    /// Chamado ao fechar, depois de copiar os cookies.
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            WebViewRepresentable(url: url, isLoading: $isLoading) { cleared = true }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if isLoading { ProgressView() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Concluído") { finish() }
                    }
                }
                .safeAreaInset(edge: .top) {
                    Text(cleared
                         ? "Verificação concluída. Toque em Concluído para voltar."
                         : "Se aparecer uma verificação, conclua-a e toque em Concluído.")
                        .font(.caption)
                        .foregroundStyle(cleared ? Theme.positive : Theme.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
                }
        }
    }

    private func finish() {
        Task { @MainActor in
            await CloudflareCookies.copyToApp()
            onDone()
            dismiss()
        }
    }
}

enum CloudflareCookies {
    /// Copia os cookies da WebView para o `HTTPCookieStorage` usado pelo `HTTPClient`.
    @MainActor
    static func copyToApp() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
    }
}

private struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    var onCleared: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = HTTPClient.browserUserAgent
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        // Cookies que o app já tem (de verificações anteriores) também valem na WebView.
        let store = config.websiteDataStore.httpCookieStore
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] { store.setCookie(cookie) }
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewRepresentable

        init(_ parent: WebViewRepresentable) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            // A página de desafio se chama "Just a moment..."; quando sai dela e há cf_clearance, passou.
            guard webView.title?.localizedCaseInsensitiveContains("just a moment") != true else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [parent] cookies in
                if cookies.contains(where: { $0.name == "cf_clearance" }) {
                    Task { @MainActor in
                        await CloudflareCookies.copyToApp()
                        parent.onCleared()
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

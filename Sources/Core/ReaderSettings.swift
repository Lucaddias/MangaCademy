import Foundation
import SwiftUI
import UIKit

/// Modo de leitura (como o `ReadingMode` do Mihon). O valor é gravado no banco e em UserDefaults.
public enum ReadingMode: Int, CaseIterable, Identifiable, Codable {
    case pagedLTR = 1
    case pagedRTL = 2
    case pagedVertical = 3
    case webtoon = 4
    case webtoonGaps = 5

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .pagedLTR: return "Paginado (esquerda → direita)"
        case .pagedRTL: return "Paginado (direita → esquerda)"
        case .pagedVertical: return "Paginado vertical"
        case .webtoon: return "Webtoon"
        case .webtoonGaps: return "Webtoon com espaços"
        }
    }

    public var shortTitle: String {
        switch self {
        case .pagedLTR: return "E→D"
        case .pagedRTL: return "D→E"
        case .pagedVertical: return "Vertical"
        case .webtoon: return "Webtoon"
        case .webtoonGaps: return "Webtoon+"
        }
    }

    public var isWebtoon: Bool { self == .webtoon || self == .webtoonGaps }
    public var isRightToLeft: Bool { self == .pagedRTL }
    public var isHorizontalPaged: Bool { self == .pagedLTR || self == .pagedRTL }
}

/// O que um toque numa região da tela faz.
public enum TapAction: Equatable {
    case previous, next, menu
}

/// Layouts de zonas de toque do Mihon, numa grade 3×3.
public enum TapZoneLayout: String, CaseIterable, Identifiable {
    case lShaped, kindle, edge, rightAndLeft, disabled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lShaped: return "Em L"
        case .kindle: return "Kindle"
        case .edge: return "Bordas"
        case .rightAndLeft: return "Direita e esquerda"
        case .disabled: return "Desativado"
        }
    }

    /// Linhas de cima para baixo, colunas da esquerda para a direita.
    private var grid: [[TapAction]] {
        let p = TapAction.previous, n = TapAction.next, m = TapAction.menu
        switch self {
        case .lShaped: return [[p, p, p], [p, m, n], [n, n, n]]
        case .kindle: return [[m, m, m], [p, n, n], [p, n, n]]
        case .edge: return [[n, m, n], [n, m, n], [n, p, n]]
        case .rightAndLeft: return [[p, m, n], [p, m, n], [p, m, n]]
        case .disabled: return [[m, m, m], [m, m, m], [m, m, m]]
        }
    }

    /// Ação para um ponto normalizado (0...1). `mirrored` troca esquerda/direita (leitura D→E).
    public func action(at point: CGPoint, inversion: TapInversion, mirrored: Bool = false) -> TapAction {
        var col = min(2, max(0, Int(point.x * 3)))
        var row = min(2, max(0, Int(point.y * 3)))
        if inversion.horizontal != mirrored { col = 2 - col }
        if inversion.vertical { row = 2 - row }
        return grid[row][col]
    }

    /// Grade para a sobreposição explicativa.
    public func cells(inversion: TapInversion, mirrored: Bool) -> [[TapAction]] {
        (0..<3).map { row in
            (0..<3).map { col in
                action(at: CGPoint(x: (Double(col) + 0.5) / 3, y: (Double(row) + 0.5) / 3), inversion: inversion, mirrored: mirrored)
            }
        }
    }
}

public enum TapInversion: String, CaseIterable, Identifiable {
    case none, horizontal, vertical, both

    public var id: String { rawValue }
    var horizontal: Bool { self == .horizontal || self == .both }
    var vertical: Bool { self == .vertical || self == .both }

    public var title: String {
        switch self {
        case .none: return "Nenhuma"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .both: return "Ambas"
        }
    }
}

/// Como a página se ajusta à tela no modo paginado.
public enum PageScale: String, CaseIterable, Identifiable {
    case fitScreen, fitWidth, fitHeight, original, smart

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fitScreen: return "Ajustar à tela"
        case .fitWidth: return "Ajustar à largura"
        case .fitHeight: return "Ajustar à altura"
        case .original: return "Tamanho original"
        case .smart: return "Inteligente"
        }
    }
}

/// Onde a página começa quando é maior que a tela.
public enum ZoomStart: String, CaseIterable, Identifiable {
    case automatic, left, right, center

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automático"
        case .left: return "Esquerda"
        case .right: return "Direita"
        case .center: return "Centro"
        }
    }
}

public enum ReaderBackground: String, CaseIterable, Identifiable {
    case black, gray, white, automatic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .black: return "Preto"
        case .gray: return "Cinza"
        case .white: return "Branco"
        case .automatic: return "Automático"
        }
    }

    public func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .black: return .black
        case .gray: return Color(white: 0.2)
        case .white: return .white
        case .automatic: return scheme == .dark ? .black : .white
        }
    }
}

public enum ReaderOrientation: Int, CaseIterable, Identifiable {
    case free = 0, portrait = 1, landscape = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .free: return "Livre"
        case .portrait: return "Retrato"
        case .landscape: return "Paisagem"
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .free: return .all
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }
}

public enum ColorFilterBlend: String, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, lighten, darken

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiplicar"
        case .screen: return "Tela"
        case .overlay: return "Sobrepor"
        case .lighten: return "Clarear"
        case .darken: return "Escurecer"
        }
    }

    var blendMode: BlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .lighten: return .lighten
        case .darken: return .darken
        }
    }
}

/// Ajustes do leitor, gravados em UserDefaults (equivalente ao `ReaderPreferences` do Mihon).
@MainActor
@Observable
public final class ReaderSettings {
    public static let shared = ReaderSettings()

    private let defaults: UserDefaults

    public var defaultMode: ReadingMode { didSet { set(defaultMode.rawValue, "reader_default_mode") } }
    public var tapZones: TapZoneLayout { didSet { set(tapZones.rawValue, "reader_tap_zones") } }
    public var tapInversion: TapInversion { didSet { set(tapInversion.rawValue, "reader_tap_inversion") } }
    public var pageScale: PageScale { didSet { set(pageScale.rawValue, "reader_page_scale") } }
    public var zoomStart: ZoomStart { didSet { set(zoomStart.rawValue, "reader_zoom_start") } }
    public var cropBorders: Bool { didSet { set(cropBorders, "reader_crop_borders") } }
    /// Margem lateral no Webtoon, em % da largura (0–25).
    public var webtoonSidePadding: Double { didSet { set(webtoonSidePadding, "reader_webtoon_padding") } }
    public var background: ReaderBackground { didSet { set(background.rawValue, "reader_background") } }
    public var showPageNumber: Bool { didSet { set(showPageNumber, "reader_show_page_number") } }
    public var keepScreenOn: Bool { didSet { set(keepScreenOn, "reader_keep_screen_on") } }
    public var defaultOrientation: ReaderOrientation { didSet { set(defaultOrientation.rawValue, "reader_orientation") } }
    public var dualPageInLandscape: Bool { didSet { set(dualPageInLandscape, "reader_dual_page") } }
    public var rotateWidePages: Bool { didSet { set(rotateWidePages, "reader_rotate_wide") } }
    /// Escurecimento próprio do leitor (0 = nenhum, 0.8 = máximo).
    public var dimming: Double { didSet { set(dimming, "reader_dimming") } }
    public var grayscale: Bool { didSet { set(grayscale, "reader_grayscale") } }
    public var invertColors: Bool { didSet { set(invertColors, "reader_invert") } }
    public var colorFilterEnabled: Bool { didSet { set(colorFilterEnabled, "reader_color_filter") } }
    public var colorFilterHex: String { didSet { set(colorFilterHex, "reader_color_filter_hex") } }
    public var colorFilterBlend: ColorFilterBlend { didSet { set(colorFilterBlend.rawValue, "reader_color_filter_blend") } }
    public var skipRead: Bool { didSet { set(skipRead, "reader_skip_read") } }
    public var skipDuplicates: Bool { didSet { set(skipDuplicates, "reader_skip_dupes") } }
    /// Páginas baixadas antes de chegar nelas.
    public var preloadCount: Int { didSet { set(preloadCount, "reader_preload_count") } }
    public var preloadOnlyOnWifi: Bool { didSet { set(preloadOnlyOnWifi, "reader_preload_wifi") } }
    public var alwaysShowTransition: Bool { didSet { set(alwaysShowTransition, "reader_always_transition") } }
    /// Já mostrou a explicação das zonas de toque.
    public var tapZonesExplained: Bool { didSet { set(tapZonesExplained, "reader_tap_zones_explained") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        let legacyWebtoon = defaults.object(forKey: Preferences.Key.defaultReaderWebtoon) as? Bool ?? Preferences.Default.defaultReaderWebtoon
        defaultMode = ReadingMode(rawValue: value("reader_default_mode", 0)) ?? (legacyWebtoon ? .webtoon : .pagedLTR)
        tapZones = TapZoneLayout(rawValue: value("reader_tap_zones", "")) ?? .lShaped
        tapInversion = TapInversion(rawValue: value("reader_tap_inversion", "")) ?? .none
        pageScale = PageScale(rawValue: value("reader_page_scale", "")) ?? .fitScreen
        zoomStart = ZoomStart(rawValue: value("reader_zoom_start", "")) ?? .automatic
        cropBorders = value("reader_crop_borders", false)
        webtoonSidePadding = value("reader_webtoon_padding", 0.0)
        background = ReaderBackground(rawValue: value("reader_background", "")) ?? .black
        showPageNumber = value("reader_show_page_number", true)
        keepScreenOn = value("reader_keep_screen_on", true)
        defaultOrientation = ReaderOrientation(rawValue: value("reader_orientation", 0)) ?? .free
        dualPageInLandscape = value("reader_dual_page", true)
        rotateWidePages = value("reader_rotate_wide", false)
        dimming = value("reader_dimming", 0.0)
        grayscale = value("reader_grayscale", false)
        invertColors = value("reader_invert", false)
        colorFilterEnabled = value("reader_color_filter", false)
        colorFilterHex = value("reader_color_filter_hex", "#FFB34D")
        colorFilterBlend = ColorFilterBlend(rawValue: value("reader_color_filter_blend", "")) ?? .multiply
        skipRead = value("reader_skip_read", false)
        skipDuplicates = value("reader_skip_dupes", false)
        preloadCount = value("reader_preload_count", 4)
        preloadOnlyOnWifi = value("reader_preload_wifi", false)
        alwaysShowTransition = value("reader_always_transition", false)
        tapZonesExplained = value("reader_tap_zones_explained", false)
    }

    public var colorFilterColor: Color {
        get { Color(hex: colorFilterHex) ?? .orange }
        set { colorFilterHex = newValue.hexString }
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

extension Color {
    init?(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

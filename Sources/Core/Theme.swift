import SwiftUI
import UIKit

/// Tokens visuais do app: cor, espaçamento, raio e tipografia.
/// As telas não usam cores do sistema (`.secondary`, `.blue`…): tudo passa por aqui,
/// com um valor para o modo claro e outro para o escuro.
enum Theme {
    // MARK: - Cor

    /// Fundo das telas (azul gelo do círculo no claro, azul-noite profundo no escuro).
    static let canvas = Color(light: 0xEDF6FC, dark: 0x071520)
    /// Superfície acima do fundo: linhas de formulário, cartões (branco do ícone no claro, marinho da letra "A" no escuro).
    static let surface = Color(light: 0xFFFFFF, dark: 0x0B1E2D)
    /// Preenchimento discreto: chips, capas carregando, trilhos de progresso.
    static let fill = Color(light: 0x0B1E2D, lightAlpha: 0.06, dark: 0xEDF6FC, darkAlpha: 0.09)
    /// Separadores e contornos finos.
    static let hairline = Color(light: 0x0B1E2D, lightAlpha: 0.10, dark: 0xEDF6FC, darkAlpha: 0.12)

    /// Texto principal (azul-escuro da letra "A" no claro, azul gelo no escuro).
    static let ink = Color(light: 0x0B1E2D, dark: 0xEDF6FC)
    /// Texto de apoio: autor, capítulo, sinopse (tons acinzentados com subtom azulado).
    static let inkSecondary = Color(light: 0x4A6073, dark: 0x94ADC2)
    /// O que pode passar despercebido: datas, contadores, ícones inativos.
    static let inkTertiary = Color(light: 0x788F9E, dark: 0x5E768A)

    /// Cor da marca (azul do anel circular): ação principal, seleção, não lidos.
    static let accent = Color(light: 0x005EA6, dark: 0x47A3F3)
    /// Fundo leve da cor da marca.
    static let accentSoft = Color(light: 0x005EA6, lightAlpha: 0.12, dark: 0x47A3F3, darkAlpha: 0.18)
    /// Texto e ícones sobre `accent`.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x071520)

    /// Completo, baixado, deu certo.
    static let positive = Color(light: 0x2E7D5B, dark: 0x5FC69A)
    /// Atenção: capítulos faltando, verificação anti-bot, hiato, marcadores.
    static let caution = Color(light: 0x9C6400, dark: 0xF2B54A)
    /// Falhas e ações que apagam.
    static let critical = Color(light: 0xB0174A, dark: 0xFF7FA3)

    /// Véu escuro sobre capas: selos legíveis em qualquer imagem, nos dois modos.
    static let scrim = Color.black.opacity(0.55)

    /// Interruptores ligados na cor da marca (o verde do sistema destoa). Os seletores ficam em tinta neutra,
    /// por isso não dá para usar `.tint` na lista inteira.
    @MainActor
    static func applyAppearance() {
        UISwitch.appearance().onTintColor = UIColor(accent)
    }

    // MARK: - Espaço

    /// Escala de 4 pt.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Margem lateral de todas as telas.
        static let margin: CGFloat = 20
        /// Distância horizontal entre capas na grade.
        static let gutter: CGFloat = 12
        /// Distância vertical entre linhas da grade (o título fica embaixo da capa).
        static let gridRow: CGFloat = 20
    }

    enum Radius {
        /// Miniaturas em listas.
        static let thumb: CGFloat = 6
        /// Capas na grade e no detalhe.
        static let cover: CGFloat = 8
        /// Cartões e avisos.
        static let card: CGFloat = 12
    }

    // MARK: - Tipografia

    /// Papéis de texto: cada um junta tamanho, peso e nível de tinta.
    enum TextRole {
        /// Título da obra no detalhe.
        case title
        /// Cabeçalho de seção ("189 capítulos").
        case section
        /// Texto de linha (título na lista, capítulo).
        case body
        case bodyStrong
        /// Apoio: autor, sinopse, nome do capítulo nas novidades.
        case meta
        /// Datas, contadores, rodapés.
        case caption

        var font: Font {
            switch self {
            case .title: return .title3.weight(.bold)
            case .section: return .headline
            case .body: return .subheadline
            case .bodyStrong: return .subheadline.weight(.semibold)
            case .meta: return .footnote
            case .caption: return .caption
            }
        }

        var color: Color {
            switch self {
            case .title, .section, .body, .bodyStrong: return Theme.ink
            case .meta: return Theme.inkSecondary
            case .caption: return Theme.inkTertiary
            }
        }
    }
}

extension View {
    /// Aplica tamanho, peso e cor de um papel de texto.
    func textRole(_ role: Theme.TextRole) -> some View {
        font(role.font).foregroundStyle(role.color)
    }

    /// Faixa fixa no topo (filtros, categorias). O conteúdo rola por baixo dela:
    /// no iOS 26 com o efeito de borda do vidro, antes com material translúcido. Nunca um bloco sólido.
    @ViewBuilder
    func floatingHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .top) { header().environment(\.inFloatingBar, true) }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { header().environment(\.inFloatingBar, true).background(.bar) }
        }
    }

    /// Fundo de controle que flutua sobre o conteúdo (chips, busca): vidro no iOS 26+, material antes.
    @ViewBuilder
    func floatingSurface<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// Lista ou formulário sobre o fundo do app, sem o cinza do sistema.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.canvas)
    }
}

extension EnvironmentValues {
    /// Dentro de `floatingHeader`: o conteúdo rola por baixo, então os chips precisam de fundo próprio.
    @Entry var inFloatingBar = false
}

/// Chip de escolha: categorias, idiomas, ordem e tags. Escolhido = cor da marca; senão, preenchimento neutro
/// (ou vidro, quando flutua sobre as capas).
struct Chip: View {
    let title: String
    var count: Int?
    var systemImage: String?
    var isSelected = false
    /// Mostra um "x" (chip que remove ao tocar).
    var removable = false
    /// Sugestão: texto em tinta de apoio, um degrau abaixo dos outros chips.
    var muted = false
    /// Filtro principal da tela (ordem do Explorar): texto e alvo de toque maiores.
    var large = false

    @Environment(\.inFloatingBar) private var floating

    var body: some View {
        if isSelected {
            label.background(Theme.accent, in: Capsule())
        } else if floating {
            label.floatingSurface(in: Capsule())
        } else {
            label.background(Theme.fill, in: Capsule())
        }
    }

    private var label: some View {
        HStack(spacing: Theme.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font((large ? Font.footnote : .caption).weight(.semibold))
            }
            Text(title)
            if let count {
                Text("\(count)")
                    .monospacedDigit()
                    .opacity(0.7)
            }
            if removable {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
        }
        .font((large ? Font.subheadline : .footnote).weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, large ? Theme.Space.l : Theme.Space.m)
        .padding(.vertical, large ? 10 : 7)
        .foregroundStyle(isSelected ? Theme.onAccent : (muted ? Theme.inkSecondary : Theme.ink))
        .contentShape(Capsule())
    }
}

/// Selo pequeno sobre a capa (idiomas, fontes, baixados).
struct CoverBadge: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.scrim
    var foreground: Color = .white

    var body: some View {
        HStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(foreground)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tint, in: Capsule())
    }
}

extension Color {
    /// Cor que muda entre claro e escuro, a partir de hexadecimais (0xRRGGBB).
    init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

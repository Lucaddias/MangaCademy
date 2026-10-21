<div align="center">

<img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="MangaCademy" width="128" height="128">

# MangaCademy

**Um leitor de mangá, manhwa e manhua nativo para iOS que reúne centenas de fontes em um único catálogo.**

[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-000000?logo=apple&logoColor=white)](#requisitos)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0D96F6?logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![SwiftData](https://img.shields.io/badge/persist%C3%AAncia-SwiftData-5856D6)](https://developer.apple.com/xcode/swiftdata/)
[![Fontes](https://img.shields.io/badge/fontes-440%2B-0A5BB5)](#fontes)

[Recursos](#recursos) •
[Fontes](#fontes) •
[Como funciona](#como-funciona) •
[Instalação](#instalação) •
[Arquitetura](#arquitetura) •
[Aviso legal](#aviso-legal)

</div>

---

## Sobre

O MangaCademy transforma as extensões do repositório [**Keiyoushi**](https://github.com/keiyoushi/extensions) em um catálogo único e infinito no iPhone. A mesma obra publicada por dezenas de sites, em vários idiomas, aparece **uma única vez**, com todos os capítulos unificados e separados por idioma.

Como as extensões originais são APKs Android, o app reimplementa em Swift os temas e APIs usados por elas. Nada é executado a partir de código de terceiros: tudo roda nativamente.

## Recursos

- 📚 **Catálogo infinito** — consulta todas as fontes em rodízio e continua carregando até a última página da última fonte.
- 🔗 **Unificação inteligente de obras** — a mesma obra em fontes e idiomas diferentes vira um único card, reconhecida por:
  - títulos e títulos alternativos idênticos;
  - títulos traduzidos com o mesmo significado (_“Ilusão de Amor: Superstar”_ = _“Love is an Illusion! - Superstar”_ = _“El amor es una ilusión Superstar”_);
  - impressão digital da capa (dHash), que reconhece a mesma arte mesmo redimensionada.
- 🌎 **Filtro rápido de idioma** — Português, Inglês ou Todos. Cada obra mostra apenas os capítulos disponíveis no idioma escolhido.
- 🧩 **Capítulos sem repetição** — capítulos de várias scans são mesclados e deduplicados por número.
- 🔞 **Bloqueio de conteúdo adulto** — esconde obras com as tags _Adult_, _Adulto_ ou _+18_ (ligado por padrão, ajustável em Ajustes). Tags como _Vida Adulta_ não são afetadas.
- 📖 **Leitor Webtoon e paginado**, com progresso, histórico e biblioteca salvos localmente.
- ⚡ **Cache em disco** de capas e metadados, para abrir o catálogo de novo sem refazer o trabalho.
- 🩺 **Fontes resilientes** — sites fora do ar ou atrás de proteção anti-bot são consultados por último e não travam o restante.

## Fontes

O índice de extensões vem do repositório [keiyoushi/extensions](https://github.com/keiyoushi/extensions) e é atualizado dentro do app (Ajustes → Atualizar índice do repositório).

| Motor | Tipo | Exemplos |
| --- | --- | --- |
| **Madara** | Tema WordPress | Centenas de scans em PT, EN, ES e outros idiomas |
| **MangaThemesia** | Tema WordPress | Tsundoku Traduções e similares |
| **ZeistManga** | Tema Blogger | Ler 999 e similares |
| **Keyoapp** | Tema | Mist Scans e similares |
| **Iken** | API JSON | Ken Scans e similares |
| **MangaDex** | API oficial | Multi-idioma |
| **ComicK** | API | Multi-idioma |
| **NexusToons** | API cifrada | Português |
| **Weeb Central** | HTML (HTMX) | Inglês |

> [!NOTE]
> Sites protegidos por Cloudflare ou bloqueados pela sua rede/DNS podem não responder. O app segue funcionando com as demais fontes.

## Como funciona

```mermaid
flowchart LR
    A[Índice Keiyoushi] --> B[SourceManager]
    B --> C[CatalogFeed<br/>rodízio entre fontes]
    C --> D{Verificação}
    D -->|títulos alternativos<br/>e tags| E[WorkMerger]
    D -->|hash da capa| E
    D -->|tag adulta| F[Oculta]
    E --> G[Grade infinita]
    G --> H[Detalhe da obra<br/>capítulos por idioma]
    H --> I[Leitor]
```

1. **Coleta** — o `CatalogFeed` pede páginas a cada fonte em rodízio, conforme a rolagem.
2. **Verificação** — antes de aparecer, cada obra nova recebe títulos alternativos, tags e a impressão digital da capa (com cache de 14 dias).
3. **Unificação** — o `WorkMerger` decide se a obra é nova ou se pertence a uma obra existente.
4. **Leitura** — o detalhe carrega todas as fontes da obra, agrupa os capítulos por idioma e remove duplicatas.

## Instalação

### Requisitos

- macOS com **Xcode 16** ou superior
- iPhone ou simulador com **iOS 17** ou superior

### Compilando

```bash
git clone https://github.com/Lucaddias/MangaCademy.git
cd MangaCademy
open MangaCademy.xcodeproj
```

No Xcode, escolha seu time em **Signing & Capabilities**, selecione o dispositivo e pressione <kbd>⌘</kbd> + <kbd>R</kbd>.

## Arquitetura

```
Sources/
├── App/          # Ponto de entrada e navegação por abas
├── Core/         # Catálogo, unificação, filtros, HTTP e parser HTML (libxml2)
├── Models/       # Modelos de fonte e de domínio (SwiftData)
├── Services/     # Índice Keiyoushi e cache de imagens
├── Sources/      # Implementações das fontes
│   └── Engines/  # Temas reutilizáveis (Madara, MangaThemesia, Iken…)
└── Views/        # Explorar, Biblioteca, Histórico, Detalhe, Leitor e Ajustes
```

| Componente | Responsabilidade |
| --- | --- |
| `CatalogFeed` | Paginação infinita, concorrência e verificação antes de exibir |
| `WorkMerger` | Unificação por título, conceitos traduzidos e capa |
| `TitleConcepts` | Normaliza títulos PT/ES/FR para conceitos em inglês |
| `CoverFingerprint` | dHash de 64 bits das capas |
| `ContentFilter` | Regras do bloqueio de tags adultas |
| `SourceAggregator` | Agrupa e deduplica capítulos por idioma |

## Contribuindo

Contribuições são bem-vindas! Abra uma _issue_ para relatar fontes quebradas ou obras unificadas incorretamente, ou envie um _pull request_.

1. Faça um fork do projeto
2. Crie sua branch (`git checkout -b feature/minha-fonte`)
3. Faça commit das mudanças (`git commit -m 'Adiciona fonte X'`)
4. Envie (`git push origin feature/minha-fonte`) e abra um pull request

## Aviso legal

O MangaCademy **não hospeda nenhum conteúdo**. Ele apenas exibe material disponibilizado publicamente por sites de terceiros, da mesma forma que um navegador. Os direitos das obras pertencem aos seus autores e editoras — apoie os lançamentos oficiais sempre que possível.

## Agradecimentos

- [Keiyoushi](https://github.com/keiyoushi/extensions) — pelo índice de extensões e pela documentação das fontes
- A todas as scans e tradutores que mantêm as obras acessíveis

<div align="center">

Feito com ☕ e SwiftUI por [Lucaddias](https://github.com/Lucaddias)

</div>

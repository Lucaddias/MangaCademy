import Foundation
import Testing
@testable import MihonReader

struct GenreTagsTests {
    @Test func synonymsInSeveralLanguagesShareOneTag() {
        let school = GenreTags.key(for: "Escolar")
        #expect(GenreTags.key(for: "School Life") == school)
        #expect(GenreTags.key(for: "school-life") == school)
        #expect(GenreTags.key(for: "Vida Escolar") == school)
        #expect(GenreTags.key(for: "SCI-FI") == GenreTags.key(for: "Ficção científica"))
        #expect(GenreTags.key(for: "Science Fiction") == GenreTags.key(for: "ciencia ficcion"))
        #expect(GenreTags.key(for: "Boys' Love") == GenreTags.key(for: "yaoi"))
        #expect(GenreTags.label(for: school) == "Escolar")
    }

    @Test func unknownTagsStillMatchByText() {
        let key = GenreTags.key(for: "Cultivo de Arroz")
        #expect(key == GenreTags.key(for: "cultivo de arroz"))
        #expect(GenreTags.matches(["Cultivo de Arroz", "Drama"], all: [key]))
        #expect(!GenreTags.matches(["Drama"], all: [key]))
        #expect(GenreTags.matches(["Drama"], all: []))
    }

    @Test func countsMergeSynonymsAndKeepTheCommonSpelling() {
        let counts = GenreTags.counts([
            ["Romance", "School Life", "Cultivo de Arroz"],
            ["Romântico", "Escolar", "Cultivo de Arroz"],
            ["Romance", "romance", "cultivo de arroz"],
            ["Drama"],
        ])
        let romance = counts.first { $0.key == GenreTags.key(for: "romance") }
        #expect(romance?.label == "Romance")
        // A mesma obra com "Romance" e "romance" conta uma vez só
        #expect(romance?.count == 3)
        #expect(counts.first { $0.label == "Escolar" }?.count == 2)
        // Desconhecida: a grafia mais comum vira o nome
        #expect(counts.first { $0.key == GenreTags.key(for: "cultivo de arroz") }?.label == "Cultivo de Arroz")
        // Gêneros fixos antes das outras tags, mesmo que a outra seja mais comum
        #expect(counts.map(\.label) == ["Romance", "Escolar", "Drama", "Cultivo de Arroz"])
    }

    @Test func allGenresComeFirstEvenWithoutWorks() {
        let counts = GenreTags.counts([["Cultivo de Arroz", "Drama"]], includeAllGenres: true)
        #expect(counts.count == GenreTags.genres.count + 1)
        #expect(counts.first?.label == "Drama")
        #expect(counts.last?.label == "Cultivo de Arroz")
        let genresFirst = counts.dropLast().allSatisfy { $0.isGenre }
        #expect(genresFirst)
        #expect(counts.first { $0.label == "Murim" }?.count == 0)
        #expect(GenreTags.counts([]).isEmpty)
    }

    @Test func asianCyrillicArabicThaiAndPolishTagsJoinTheGenres() {
        let romance = GenreTags.key(for: "Romance")
        for tag in ["恋愛", "ロマンス", "恋爱", "戀愛", "로맨스", "Романтика", "رومانسي", "โรแมนติก", "Romans"] {
            #expect(GenreTags.key(for: tag) == romance, "\(tag)")
        }
        #expect(GenreTags.key(for: "アクション") == GenreTags.key(for: "Action"))
        #expect(GenreTags.key(for: "異世界") == GenreTags.key(for: "Isekai"))
        #expect(GenreTags.key(for: "회귀") == GenreTags.key(for: "Regression"))
        #expect(GenreTags.key(for: "Фантастика") == GenreTags.key(for: "Sci-Fi"))
        #expect(GenreTags.key(for: "Фэнтези") == GenreTags.key(for: "Fantasy"))
    }

    @Test func falseFriendsStayOutOfRomance() {
        let romance = GenreTags.key(for: "Romance")
        // "Livro" em polonês, russo, francês e alemão
        for tag in ["Powieść", "Роман", "Roman", "Novel", "ラブコメ"] {
            #expect(GenreTags.key(for: tag) != romance, "\(tag)")
        }
        // Sozinho, 少女 é a menina da história, não a demografia
        #expect(!GenreTags.key(for: "少女").contains("shoujo"))
    }

    @Test func searchFindsGenresBySynonymPieces() {
        let romance = GenreTags.Count(key: GenreTags.key(for: "romance"), label: "Romance", count: 0)
        #expect(GenreTags.search("roman", matches: romance))
        #expect(GenreTags.search("恋", matches: romance))
        #expect(GenreTags.search("романт", matches: romance))
        #expect(!GenreTags.search("terror", matches: romance))
        let unknown = GenreTags.Count(key: GenreTags.key(for: "Cultivo de Arroz"), label: "Cultivo de Arroz", count: 2)
        #expect(GenreTags.search("arroz", matches: unknown))
        #expect(GenreTags.search("cultivo-de-arroz", matches: unknown))
    }

    @Test func noSynonymBelongsToTwoGenres() {
        var owner: [String: String] = [:]
        var conflicts: [String] = []
        for genre in GenreTags.genres {
            for synonym in genre.synonyms {
                let normalized = GenreTags.normalize(synonym)
                if let other = owner[normalized], other != genre.key {
                    conflicts.append("\(synonym): \(other) e \(genre.key)")
                }
                owner[normalized] = owner[normalized] ?? genre.key
            }
        }
        #expect(conflicts.isEmpty, "\(conflicts)")
    }
}

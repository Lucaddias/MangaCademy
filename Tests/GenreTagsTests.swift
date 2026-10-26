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
        #expect(counts.count == 4)
        #expect(counts.last?.label == "Drama")
    }
}

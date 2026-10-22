import Foundation
import Testing
@testable import MihonReader

struct ReaderLogicTests {
    @Test func lShapedZones() {
        let layout = TapZoneLayout.lShaped
        #expect(layout.action(at: CGPoint(x: 0.5, y: 0.1), inversion: .none) == .previous)
        #expect(layout.action(at: CGPoint(x: 0.5, y: 0.5), inversion: .none) == .menu)
        #expect(layout.action(at: CGPoint(x: 0.9, y: 0.5), inversion: .none) == .next)
        #expect(layout.action(at: CGPoint(x: 0.1, y: 0.9), inversion: .none) == .next)
    }

    /// Na leitura da direita para a esquerda, tocar à esquerda avança.
    @Test func rightToLeftMirrorsZones() {
        let layout = TapZoneLayout.rightAndLeft
        #expect(layout.action(at: CGPoint(x: 0.1, y: 0.5), inversion: .none) == .previous)
        #expect(layout.action(at: CGPoint(x: 0.1, y: 0.5), inversion: .none, mirrored: true) == .next)
        // Inverter de novo desfaz o espelhamento.
        #expect(layout.action(at: CGPoint(x: 0.1, y: 0.5), inversion: .horizontal, mirrored: true) == .previous)
    }

    @Test func kindleVerticalInversion() {
        #expect(TapZoneLayout.kindle.action(at: CGPoint(x: 0.5, y: 0.05), inversion: .none) == .menu)
        #expect(TapZoneLayout.kindle.action(at: CGPoint(x: 0.5, y: 0.95), inversion: .vertical) == .menu)
    }

    @Test func missingChapters() {
        #expect(ChapterGaps.missing(between: 10, and: 14) == 3)
        #expect(ChapterGaps.missing(between: 14, and: 10) == 3)
        #expect(ChapterGaps.missing(between: 10, and: 10.5) == 0)
        #expect(ChapterGaps.missing(between: 10, and: 11) == 0)
        #expect(ChapterGaps.missing(between: -1, and: 30) == 0)
    }

    @Test func readerSettingsRoundTrip() async {
        let defaults = UserDefaults(suiteName: "reader-\(UUID().uuidString)")!
        await MainActor.run {
            let settings = ReaderSettings(defaults: defaults)
            #expect(settings.defaultMode == .webtoon)
            settings.defaultMode = .pagedRTL
            settings.tapZones = .kindle
            let reloaded = ReaderSettings(defaults: defaults)
            #expect(reloaded.defaultMode == .pagedRTL)
            #expect(reloaded.tapZones == .kindle)
        }
    }
}

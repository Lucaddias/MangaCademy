import XCTest

final class MihonReaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testColdLaunchOfflinePerformanceMetrics() {
        let app = XCUIApplication()
        app.launchArguments = ["--measurement-ui-empty"]
        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(
            metrics: [XCTApplicationLaunchMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["tab.library"].waitForExistence(timeout: 15))
            app.terminate()
        }
    }

    @MainActor
    func testMainNavigationLaunchesAllTabs() {
        let app = launchWithFixtures()
        for identifier in ["tab.library", "tab.updates", "tab.history", "tab.browse", "tab.settings"] {
            XCTAssertTrue(app.tabBars.buttons[identifier].exists, "Missing tab \(identifier)")
        }
        app.terminate()
    }

    @MainActor
    func testCatalogSearchAndScrollUsesLocalSource() {
        let app = launchWithFixtures()
        app.tabBars.buttons["tab.browse"].tap()

        let search = app.textFields["browse.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Fixture Catalog\n")

        let result = app.buttons["catalog.item.measurement-fixture:catalog-010"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        let results = app.scrollViews["browse.results"]
        XCTAssertTrue(results.exists)
        results.swipeUp()
        XCTAssertTrue(result.exists)
        app.terminate()
    }

    @MainActor
    func testLocalFixtureLongChapterListAndDownloadedFilter() {
        let app = launchWithFixtures()
        let work = app.buttons["library.item.measurement-fixture:library-600"]
        XCTAssertTrue(work.waitForExistence(timeout: 15))
        work.tap()

        let chapterList = app.descendants(matching: .any).matching(identifier: "detail.list").firstMatch
        XCTAssertTrue(chapterList.waitForExistence(timeout: 15))
        chapterList.swipeUp()
        chapterList.swipeDown()

        let filters = app.buttons["detail.chapter-options"]
        XCTAssertTrue(filters.exists)
        filters.tap()
        let downloaded = app.buttons["Baixados"]
        XCTAssertTrue(downloaded.waitForExistence(timeout: 10))
        downloaded.tap()
        XCTAssertTrue(app.buttons["detail.chapter.library-600/chapter/600"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testLiveNexusToonsLongChapterListUsesRealProviderData() {
        let app = XCUIApplication()
        app.launchArguments = ["--measurement-live-nexustoons"]
        app.launch()

        let work = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.item.nexustoons:")
        ).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 120), app.debugDescription)
        work.tap()

        let chapterList = app.descendants(matching: .any).matching(identifier: "detail.list").firstMatch
        XCTAssertTrue(chapterList.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.chapter.")).firstMatch
                .waitForExistence(timeout: 30),
            app.debugDescription
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            chapterList.swipeUp()
            chapterList.swipeDown()
        }
        app.terminate()
    }

    @MainActor
    func testPagedAndWebtoonReaderUseLocalPages() {
        var app = launchWithFixtures()
        openReader(for: "reader-paged", in: app)
        let paged = app.descendants(matching: .any).matching(identifier: "reader.paged").firstMatch
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(paged.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "reader.page.1").firstMatch.exists)
        app.buttons["reader.close"].tap()
        app.terminate()

        app = launchWithFixtures()
        openReader(for: "reader-webtoon", in: app)
        let webtoon = app.descendants(matching: .any).matching(identifier: "reader.webtoon").firstMatch
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(webtoon.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "reader.page.1").firstMatch.exists)
        webtoon.swipeUp()
        app.terminate()
    }

    @MainActor
    func testLibraryUpdateAndLocalDownloadQueue() {
        let app = launchWithFixtures()
        let actions = app.buttons["library.actions-menu"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        let update = app.buttons["Atualizar biblioteca"]
        XCTAssertTrue(update.waitForExistence(timeout: 10))
        update.tap()

        app.tabBars.buttons["tab.updates"].tap()
        XCTAssertTrue(app.staticTexts["Capítulo 601"].waitForExistence(timeout: 20))
        app.tabBars.buttons["tab.library"].tap()

        let work = app.buttons["library.item.measurement-fixture:download-one"]
        XCTAssertTrue(work.waitForExistence(timeout: 15))
        work.tap()
        let downloadMenu = app.buttons["detail.download-menu"]
        XCTAssertTrue(downloadMenu.waitForExistence(timeout: 10))
        downloadMenu.tap()
        let all = app.buttons["Todos"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        all.tap()
        XCTAssertTrue(app.buttons["Baixado, toque para apagar"].waitForExistence(timeout: 20))
        app.terminate()
    }

    @MainActor
    func testLiveNexusToonsWarmCacheRetainedAcrossRelaunches() {
        let warmup = launchLiveReader(cacheCold: false)
        warmup.terminate()

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let app = launchLiveReader(cacheCold: false)
            app.terminate()
        }
    }

    @MainActor
    func testLiveNexusToonsColdCacheClearedBeforeEveryRelaunch() {
        let warmup = launchLiveReader(cacheCold: true)
        warmup.terminate()

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let app = launchLiveReader(cacheCold: true)
            app.terminate()
        }
    }

    @MainActor
    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--measurement-ui-fixtures"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["tab.library"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func openReader(for remoteUrl: String, in app: XCUIApplication) {
        let work = app.buttons["library.item.measurement-fixture:\(remoteUrl)"]
        XCTAssertTrue(work.waitForExistence(timeout: 15))
        work.tap()
        let chapter = app.buttons["detail.chapter.\(remoteUrl)/chapter/3"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 15))
        chapter.tap()
    }

    @MainActor
    private func launchLiveReader(cacheCold: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--measurement-live-nexustoons"]
        if cacheCold { app.launchArguments.append("--measurement-cache-cold") }
        app.launch()

        let continueReading = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.continue.nexustoons:")
        ).firstMatch
        XCTAssertTrue(continueReading.waitForExistence(timeout: 120), app.debugDescription)
        continueReading.tap()

        let page = app.descendants(matching: .any).matching(identifier: "reader.page.1").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(page.images.firstMatch.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertFalse(page.staticTexts["Erro ao carregar página 1"].exists)
        return app
    }
}

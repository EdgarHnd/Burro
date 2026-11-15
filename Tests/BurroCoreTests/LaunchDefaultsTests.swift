// The New chat sheet's memory and form: per-project choices, the provider and built-in fallbacks,
// dropping efforts and models that no longer apply, recent-project order, the legacy migration,
// prefilled drafts (including Retry) and the request the form builds.
import XCTest
@testable import BurroCore

final class LaunchDefaultsTests: XCTestCase {
    let codexModels = [
        LaunchModel(id: "gpt-5.5", title: "GPT-5.5", efforts: ["low", "medium", "high", "xhigh"], isDefault: true),
        LaunchModel(id: "gpt-5.5-mini", title: "GPT-5.5 mini", efforts: ["low", "medium"]),
    ]
    func models(_ provider: LaunchProvider) -> [LaunchModel] { provider == .codex ? codexModels : LaunchModel.claude }
    func request(_ provider: LaunchProvider, _ folder: String, model: String? = nil, effort: String? = nil,
                 access: LaunchAccess = .ask) -> LaunchRequest {
        LaunchRequest(provider: provider, prompt: "Fix it", folder: folder, model: model, effort: effort, access: access)
    }

    func testNothingRememberedUsesTheBuiltInDefaults() {
        let choice = LaunchDefaults().choice(for: "/p/a", models: models)
        XCTAssertEqual(choice, LaunchChoice(provider: .codex, model: "", effort: "", access: .ask))
        let claude = LaunchDefaults().choice(for: "/p/a", provider: .claude, models: models)
        XCTAssertEqual(claude, LaunchChoice(provider: .claude, model: "claude-opus-5-5", effort: "", access: .ask))
    }

    func testEachProjectRemembersItsLastLaunch() {
        var defaults = LaunchDefaults()
        defaults.record(request(.claude, "/p/a", model: "claude-sonnet-5-5", effort: "low", access: .edit))
        defaults.record(request(.codex, "/p/b", model: "gpt-5.5", effort: "high", access: .readOnly))
        XCTAssertEqual(defaults.choice(for: "/p/a", models: models),
                       LaunchChoice(provider: .claude, model: "claude-sonnet-5-5", effort: "low", access: .edit))
        XCTAssertEqual(defaults.choice(for: "/p/b/", models: models),
                       LaunchChoice(provider: .codex, model: "gpt-5.5", effort: "high", access: .readOnly), "trailing slash is the same project")
    }

    func testAProjectWithoutMemoryFallsBackToTheLastProviderAndItsValues() {
        var defaults = LaunchDefaults()
        defaults.record(request(.claude, "/p/a", model: "claude-haiku-5-5", effort: "max", access: .edit))
        XCTAssertEqual(defaults.choice(for: "/p/new", models: models),
                       LaunchChoice(provider: .claude, model: "claude-haiku-5-5", effort: "max", access: .edit))
    }

    func testSwitchingProviderInAProjectBringsBackThatProvidersModel() {
        var defaults = LaunchDefaults()
        defaults.record(request(.codex, "/p/a", model: "gpt-5.5-mini", effort: "low", access: .readOnly))
        defaults.record(request(.claude, "/p/a", model: "claude-fable-5-2", effort: "high", access: .edit))
        defaults.record(request(.codex, "/p/other", model: "gpt-5.5", effort: "xhigh"))
        // The project's own Codex memory wins over Codex's last values elsewhere.
        XCTAssertEqual(defaults.choice(for: "/p/a", provider: .codex, models: models),
                       LaunchChoice(provider: .codex, model: "gpt-5.5-mini", effort: "low", access: .edit))
        XCTAssertEqual(defaults.choice(for: "/p/a", models: models).provider, .claude)
    }

    func testAWorktreeBorrowsItsRepositorysMemory() {
        var defaults = LaunchDefaults()
        defaults.record(request(.claude, "/p/repo", model: "claude-sonnet-5-5", access: .edit))
        defaults.record(request(.codex, "/p/elsewhere"))
        XCTAssertEqual(defaults.choice(for: "/p/repo-wt", parent: "/p/repo", models: models).provider, .claude)
        XCTAssertEqual(defaults.choice(for: "/p/repo-wt", models: models).provider, .codex)
    }

    func testAnUnsupportedEffortIsDropped() {
        var defaults = LaunchDefaults()
        defaults.record(request(.codex, "/p/a", model: "gpt-5.5-mini", effort: "xhigh"))
        XCTAssertEqual(defaults.choice(for: "/p/a", models: models).effort, "")
        // The default model's efforts apply when the model is "default".
        XCTAssertEqual(LaunchChoice(provider: .codex, model: "", effort: "max").validated(models: codexModels).effort, "")
        XCTAssertEqual(LaunchChoice(provider: .codex, model: "", effort: "high").validated(models: codexModels).effort, "high")
    }

    func testAModelNoLongerOfferedFallsBackToTheDefault() {
        XCTAssertEqual(LaunchChoice(provider: .codex, model: "gpt-4", effort: "").validated(models: codexModels).model, "")
        XCTAssertEqual(LaunchChoice(provider: .claude, model: "claude-old", effort: "").validated(models: LaunchModel.claude).model, "claude-opus-5-5")
        // Codex models not loaded yet: keep what was remembered.
        XCTAssertEqual(LaunchChoice(provider: .codex, model: "gpt-4", effort: "high").validated(models: []),
                       LaunchChoice(provider: .codex, model: "gpt-4", effort: "high"))
    }

    func testRecentProjectsComeFirstAndStayCapped() {
        var defaults = LaunchDefaults()
        for index in 0..<(LaunchDefaults.projectLimit + 5) { defaults.record(request(.codex, "/p/\(index)")) }
        XCTAssertEqual(defaults.recentProjects.count, LaunchDefaults.projectLimit)
        XCTAssertEqual(defaults.projects.count, LaunchDefaults.projectLimit)
        XCTAssertEqual(defaults.recentProjects.first, "/p/\(LaunchDefaults.projectLimit + 4)")
        XCTAssertNil(defaults.projects["/p/0"], "the oldest memory is forgotten")

        var small = LaunchDefaults()
        small.record(request(.codex, "/p/wt"))
        small.record(request(.codex, "/p/gone"))
        small.record(request(.codex, "/p/b"))
        let ordered = small.orderedProjects(known: [("/p/a", "a"), ("/p/b", "b")], exists: { $0 != "/p/gone" })
        XCTAssertEqual(ordered.map(\.path), ["/p/b", "/p/wt", "/p/a"])
        XCTAssertEqual(ordered[1].name, "wt")
        XCTAssertEqual(small.lastProject(exists: { _ in true }), "/p/b")
    }

    func testMigratesTheOldPerProviderPreferences() {
        let legacy: [String: Any] = ["launch.provider": "claude", "launch.access": "edit", "launch.model.claude": "claude-sonnet-5-5",
                                     "launch.effort.claude": "low", "launch.model.codex": "", "launch.folder": "/p/a/"]
        let defaults = LaunchDefaults.migrating { legacy[$0] }
        XCTAssertEqual(defaults.recentProjects, ["/p/a"])
        XCTAssertEqual(defaults.choice(for: "/p/a", models: models),
                       LaunchChoice(provider: .claude, model: "claude-sonnet-5-5", effort: "low", access: .edit))
        XCTAssertEqual(defaults.choice(for: "/p/a", provider: .codex, models: models),
                       LaunchChoice(provider: .codex, model: "", effort: "", access: .edit))
        XCTAssertEqual(LaunchDefaults.migrating { _ in nil }, LaunchDefaults())
    }

    func testRoundTripsAndToleratesDamage() {
        var defaults = LaunchDefaults()
        defaults.record(request(.claude, "/p/a", model: "claude-opus-5-5", effort: "high", access: .edit))
        XCTAssertEqual(LaunchDefaults.decode(defaults.encoded()), defaults)
        XCTAssertNil(LaunchDefaults.decode(Data("not json".utf8)))
        XCTAssertNil(LaunchDefaults.decode(Data(repeating: 32, count: 300 * 1024)))
        XCTAssertNil(LaunchDefaults.decode(nil))
    }

    func testFormFromADraftAndItsRequest() {
        var defaults = LaunchDefaults()
        defaults.record(request(.claude, "/p/a", model: "claude-sonnet-5-5", effort: "low", access: .edit))
        var form = LaunchForm(draft: LaunchDraft(prompt: "Ship it", folder: "/p/a/"), fallbackFolder: "/p/z", defaults: defaults, models: models)
        XCTAssertEqual(form.folder, "/p/a")
        XCTAssertNil(form.machine, "this round always runs on this Mac")
        XCTAssertEqual(form.request, LaunchRequest(provider: .claude, prompt: "Ship it", folder: "/p/a", model: "claude-sonnet-5-5",
                                                   effort: "low", access: .edit))
        form.selectProvider(.codex, defaults: defaults, models: models)
        XCTAssertEqual(form.choice, LaunchChoice(provider: .codex, model: "", effort: "", access: .edit), "access stays when switching provider")
        form.selectModel("gpt-5.5", models: codexModels)
        form.choice.effort = "xhigh"
        form.selectModel("gpt-5.5-mini", models: codexModels)
        XCTAssertEqual(form.choice.effort, "", "the mini model has no xhigh")
        XCTAssertEqual(form.request.model, "gpt-5.5-mini")
        XCTAssertNil(form.request.effort)

        form.selectProject("/p/new", defaults: defaults, models: models)
        XCTAssertEqual(form.prompt, "Ship it", "the prompt survives a project change")
        XCTAssertEqual(form.choice.provider, .claude)

        let blank = LaunchForm(draft: LaunchDraft(), fallbackFolder: "/p/z", defaults: defaults, models: models)
        XCTAssertEqual(blank.folder, "/p/z")
        XCTAssertFalse(blank.canStart)
        XCTAssertFalse(LaunchForm(prompt: "  \n", folder: "/p").canStart)
        XCTAssertFalse(LaunchForm(prompt: "Go", folder: "").canStart)
    }

    func testRetryReopensWithTheExactRequest() {
        let failed = request(.codex, "/p/a", model: "gpt-5.5", effort: "high", access: .readOnly)
        var defaults = LaunchDefaults()
        defaults.record(request(.claude, "/p/a"))
        let form = LaunchForm(draft: LaunchDraft(retrying: failed), fallbackFolder: "", defaults: defaults, models: models)
        XCTAssertEqual(form.request, failed)
    }

    func testPromptAndProjectFromAToDo() {
        XCTAssertEqual(LaunchDraft.prompt(from: "  Fix the login bug \n"), "Fix the login bug")
        XCTAssertEqual(LaunchDraft.prompt(from: String(repeating: "a", count: 9_000)).count, LaunchDraft.promptLimit)
        let known = [(path: "/p/Burro", name: "Burro"), (path: "/p/focustown", name: "FocusTown")]
        XCTAssertEqual(LaunchDraft.folder(forProject: "focustown", among: known, exists: { _ in false }), "/p/focustown")
        XCTAssertEqual(LaunchDraft.folder(forProject: "/p/elsewhere/", among: known, exists: { $0 == "/p/elsewhere" }), "/p/elsewhere")
        XCTAssertNil(LaunchDraft.folder(forProject: "/p/missing", among: known, exists: { _ in false }))
        XCTAssertNil(LaunchDraft.folder(forProject: "Unknown", among: known, exists: { _ in true }))
        XCTAssertNil(LaunchDraft.folder(forProject: nil, among: known, exists: { _ in true }))
        XCTAssertNil(LaunchDraft.folder(forProject: "  ", among: known, exists: { _ in true }))
    }
}

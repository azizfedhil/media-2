import SwiftUI

/// Settings -> Content & catalogues: what shows up on Home, Explore and in recommendations.
/// Saved per profile, so a kids' profile can hide what an adult's doesn't.
struct ContentSettingsView: View {
    @Environment(ContentPrefs.self) private var prefs
    @Environment(AddonStore.self) private var store
    @Environment(ProfileStore.self) private var profiles
    @AppStorage("tmdb.key") private var tmdbKey = ""

    private var rules: ContentRules { prefs.rules }
    private var hidesAnimation: Bool { rules.hiddenCategories.contains(.anime) || rules.hiddenCategories.contains(.cartoons) }
    private var catalogAddons: [Addon] { store.addons.filter { !$0.homeCatalogs.isEmpty } }

    var body: some View {
        Form {
            Section {
                ForEach(ContentCategory.allCases) { c in
                    Toggle(isOn: shown(c)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(c.title, systemImage: c.symbol)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Show these kinds of titles · \(profiles.active.name)")
            } footer: {
                Text(categoryFooter)
            }

            Section {
                rowToggle("Trending Movies", key: ContentRules.Builtin.trendingMovies, symbol: "flame.fill")
                rowToggle("Trending Shows", key: ContentRules.Builtin.trendingShows, symbol: "flame.fill")
                rowToggle("Because you watched", key: ContentRules.Builtin.because, symbol: "sparkles")
                rowToggle("Themed collections", key: ContentRules.Builtin.themes, symbol: "square.stack.fill")
            } header: {
                Text("Home rows")
            } footer: {
                Text("You can also touch and hold a row's title on Home and choose Hide this row.")
            }

            ForEach(catalogAddons) { addon in
                Section {
                    ForEach(addon.homeCatalogs, id: \.self) { cat in
                        rowToggle(catalogTitle(cat), key: ContentRules.rowKey(addon, cat), symbol: "film.stack")
                    }
                } header: {
                    Text(store.isEnabled(addon) ? addon.manifest.name : "\(addon.manifest.name) (add-on is off)")
                } footer: {
                    if addon.id == catalogAddons.last?.id {
                        Text("Catalogues come from your add-ons. Switching one off here hides its row; the add-on itself stays installed.")
                    }
                }
            }

            Section {
                Toggle("Also filter search results", isOn: Binding(
                    get: { rules.filterSearch }, set: { prefs.setFilterSearch($0) }))
            } header: {
                Text("Search")
            } footer: {
                Text("Off by default: a search names exactly what you're after. Turn it on to apply the categories above to search too. Titles you added yourself (Continue Watching, your library) are never hidden.")
            }

            Section {
                Button("Show everything again", role: .destructive) { prefs.reset() }
                    .disabled(rules == ContentRules())
            }
        }
        .navigationTitle("Content & catalogues")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Pieces

    private var categoryFooter: String {
        var text = "Hidden titles are removed from Home, Explore, recommendations and themed collections."
        if hidesAnimation && tmdbKey.isEmpty {
            text += " Without a TMDB key (Settings → Integrations) anime and cartoons can't be told apart, so all animation is hidden while either is off."
        }
        return text
    }

    private func shown(_ c: ContentCategory) -> Binding<Bool> {
        Binding(get: { !rules.hiddenCategories.contains(c) }, set: { prefs.setHidden(c, !$0) })
    }

    private func rowToggle(_ title: String, key: String, symbol: String) -> some View {
        Toggle(isOn: Binding(get: { !rules.isRowHidden(key) }, set: { prefs.setRowHidden(key, !$0) })) {
            Label(title, systemImage: symbol)
        }
    }

    private func catalogTitle(_ cat: AddonManifest.CatalogDef) -> String {
        let kind = cat.type == "movie" ? "Movies" : cat.type == "series" ? "Series" : cat.type.capitalized
        return "\(cat.name ?? cat.id) · \(kind)"
    }
}

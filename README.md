# MediaHub (iOS 26, SwiftUI)
App name "Pear.", version 0.1.0, bundle id `com.mediahub.pear` (set in `project.yml`).

1. `brew install xcodegen && xcodegen` (generates MediaHub.xcodeproj from project.yml)
2. Open in Xcode 26, run on an iOS 26 simulator/device.
Or: new iOS App project in Xcode 26, drag in the `MediaHub/` folder.

Next: Player (AVPlayer) -> Simkl PIN login/sync -> MDBList ratings/lists -> TVDB artwork -> Library/Search.

## Peer-to-peer (opt-in)
Torrentio torrent streams play through an embedded Rust engine (`p2p-core/`, librqbit + UniFFI). Off by default: Settings -> Peer-to-peer.
- CI builds `Vendor/P2PCore.xcframework` before `xcodegen` (see `.github/workflows/build.yml`). Locally: `cd p2p-core && make xcframework`.
- Swift side lives in `MediaHub/P2P/`. Engine only exists while a P2P stream is playing; idle/background/memory/network changes tear it down.

## Picture in Picture
The pill in the player has a PiP button (native AVPlayer path only; hidden for software-decoded AV1 / VP9). Leaving the app while a video plays opens the window automatically. Code: `MediaHub/Features/PlayerPiP.swift`.

## Content & catalogues
Settings -> Content & catalogues. Saved per profile, so a kids' profile can hide what yours doesn't.
- **Categories:** switch off Anime, Cartoons & animation, Kids & family, Documentaries, Reality TV, Talk & news, Soap operas, Horror or Romance. Hidden titles are removed from Home, Explore, recommendations, themed collections and "See all" pages. Search is unfiltered unless you turn on "Also filter search results". Continue Watching and your library are never filtered.
- **Rows:** switch off built-in Home rows and individual add-on catalogues (or touch and hold a row title on Home -> Hide this row). Hidden catalogues are skipped before the 12-row cap, so they don't use up slots.
- **AIOMetadata:** Settings -> Content & catalogues -> AIOMetadata. An AIOMetadata add-on can offer dozens of catalogues (TMDB, TVDB, MDBList, MAL, streaming services...), so unlike other add-ons none of them show on Home until you add them. Switch a catalogue on to give it a row, off (or touch and hold its row title on Home -> Remove from Home) to take it away. Saved per profile and included in settings backups; "Show everything again" leaves them alone. The add-on is recognised by \"aiometadata\" in its manifest id, name, description or host (`Addon.isAIOMetadata`); a copy hosted under another name can be switched on by hand under \"Other add-ons\" on that screen. Added rows are not counted against the 12-row cap. Code: `Features/AIOMetadataSettingsView.swift`, `ContentRules.addedRows`.
- **How titles are classified** (`Core/ContentRules.swift`, `Core/TitleClassifier.swift`): TMDB lists already carry genres and original language, and most add-ons list genre names, so most titles are decided with no extra request. Anime = Animation + Japanese origin; Cartoons = any other Animation. Titles that can't be decided (an add-on that lists no genres, or Animation with no origin) cost one small TMDB request each, run six at a time, and the answer is cached on disk forever. Kitsu/MAL/AniList items count as anime from their id alone.
- **Without a TMDB key** anime and cartoons can't be told apart, so all animation is hidden while either is off. Titles with no genre info at all stay visible.
- Adding a category: a case in `ContentCategory` plus its TMDB genre ids.

## Themed rows
Editorial collections ("Small-Town Secrets", "K-Drama Fever"...) on Home and Explore. Code: `Features/Themerows.swift`.
- **Catalogue:** `ThemeCatalog.all`, about 65 themes. Each is a set of TMDB keywords, or an original language (`language: "ko"`) for the "around the world" ones. Add your own with any phrase TMDB uses as a keyword; if the name isn't an exact match TMDB's closest hit is used, and a theme that ends up with fewer than three titles is skipped.
- **Rotation:** one daily slate of 10 themes (Home's 6 candidates, then Explore's 4), taken from seeded shuffles of the whole catalogue. Nothing repeats until every theme has had a turn, consecutive days never overlap, and Home and Explore never share a theme. Home shows 5 rows (the sixth is a spare in case one theme is empty), spread through the feed: after Continue Watching, after the suggestions, after your lists, then after every second add-on row. Explore shows 3.
- **AIOMetadata enrichment:** when an AIOMetadata add-on (or one marked as such under Settings -> Content & catalogues -> AIOMetadata) is switched on and serves `meta`, theme rows load from TMDB first and are then updated in place with the add-on's genres (the caption under the logo) and its title logo, which takes priority over the TMDB / TVDB logo for the session. Only the first 8 titles of a row are looked up; titles the add-on doesn't know keep their TMDB data. Skipped in Low Power Mode. Code: `ThemeEnrichment`, `AddonClient.metaExtras`, `LogoResolver.prefer`.


# MediaHub (iOS 26, SwiftUI)
1. `brew install xcodegen && xcodegen` (generates MediaHub.xcodeproj from project.yml)
2. Open in Xcode 26, run on an iOS 26 simulator/device.
Or: new iOS App project in Xcode 26, drag in the `MediaHub/` folder.

Next: Player (AVPlayer) -> Simkl PIN login/sync -> MDBList ratings/lists -> TVDB artwork -> Library/Search.

## Peer-to-peer (opt-in)
Torrentio torrent streams play through an embedded Rust engine (`p2p-core/`, librqbit + UniFFI). Off by default: Settings -> Peer-to-peer.
- CI builds `Vendor/P2PCore.xcframework` before `xcodegen` (see `.github/workflows/build.yml`). Locally: `cd p2p-core && make xcframework`.
- Swift side lives in `MediaHub/P2P/`. Engine only exists while a P2P stream is playing; idle/background/memory/network changes tear it down.

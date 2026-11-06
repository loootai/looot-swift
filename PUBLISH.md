# Publishing looot-swift

Swift has no registry upload. A Swift package is published when a semver tag is on a public
GitHub repo. The Swift Package Index (SPI) lists it once the repo is in its package list and
builds docs from `.spi.yml`. There is no account, no token and no trusted publisher to set up.

## Steps for Walid

1. Turn on GitHub Actions for the repo if the org has them off (Settings, Actions, General,
   Allow all actions). Public repos run them for free.
2. The `0.1.0` tag is the first release (`git tag 0.1.0 && git push origin 0.1.0`). The release
   workflow tests it and creates the GitHub release. It is pushed after CI and review pass.
3. The package is submitted to the Swift Package Index through the "Add Package(s)" issue form
   in SwiftPackageIndex/PackageList. A bot opens the pull request and a maintainer merges it,
   usually within a day or two. Nothing to do until then.
4. After the merge, open https://swiftpackageindex.com/loootai/looot-swift. The first build
   takes a few hours. If the page says the package is not found yet, wait and retry.
5. Optional: add the Swift SDK to the docs `sdks` page at docs.looot.ai with the
   `.package(url: "https://github.com/loootai/looot-swift.git", from: "0.1.0")` line.

## Next release

1. Update `loootVersion` in `Sources/Looot/Client.swift` and add a section to `CHANGELOG.md`.
2. Run `swift build && swift test` and `bash scripts/leak-scan.sh .`.
3. Commit, then `git tag 0.1.1 && git push origin main 0.1.1`. The release workflow checks that
   the tag matches `loootVersion` and creates the GitHub release from the CHANGELOG section.

Tags have no `v` prefix (`0.1.1`). SPI reads both forms, and the release workflow accepts
either. Never move or delete a pushed tag. Ship a new patch version instead.

// SPDX-License-Identifier: GPL-3.0-or-later
//
// A copied web address of a media file is downloaded and optimised as a copied file (Clop does
// the same); any other link is never fetched. With `appendClipboardResults`, results gather on
// the clipboard so one paste gives them all.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import EsclopOptimisers
import Foundation
import Testing

/// A download that never touches the network: every address it is asked for, and what it gives.
final class FakeDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [URL] = []
    let file: URL?

    /// Gives `file`, or refuses as `WebDownload` refuses a web page.
    init(file: URL?) { self.file = file }

    var addresses: [URL] { lock.withLock { asked } }

    func fetch(_ url: URL) throws -> URL {
        lock.withLock { asked.append(url) }
        guard let file else { throw EsclopError.other("\(url.absoluteString) is not an image, video, PDF or audio file (text/html)") }
        return file
    }
}

@Suite struct ClipboardAddressPolicyTests {
    let settings = TestSettings()
    var policy: ClipboardPolicy { ClipboardPolicy(factory: RequestFactory(settings: settings.store)) }
    func copy(_ types: Set<String> = ["public.utf8-plain-text"]) -> ClipboardCopy { ClipboardCopy(changeCount: 9, types: types) }

    @Test func onlyAWholeMediaAddressIsAnAddress() {
        #expect(ClipboardPolicy.address("https://example.com/photos/cove.jpg") == URL(string: "https://example.com/photos/cove.jpg"))
        #expect(ClipboardPolicy.address("  https://example.com/cove.png?w=800\n") == URL(string: "https://example.com/cove.png?w=800"), "trimmed, query kept")
        #expect(ClipboardPolicy.address("http://example.com/clip.mov") != nil)
        #expect(ClipboardPolicy.address("https://example.com/login?token=abc123") == nil, "a sign-in link is never fetched")
        #expect(ClipboardPolicy.address("https://example.com/") == nil)
        #expect(ClipboardPolicy.address("ftp://example.com/cove.jpg") == nil)
        #expect(ClipboardPolicy.address("file:///tmp/cove.jpg") == nil)
        #expect(ClipboardPolicy.address("See https://example.com/cove.jpg") == nil, "text that contains an address is not one")
        #expect(ClipboardPolicy.address("https://example.com/cove.jpg and more") == nil)
        #expect(ClipboardPolicy.address("https://example.com/a.jpg\nhttps://example.com/b.jpg") == nil)
    }

    @Test func aMediaAddressIsDownloadedWhenItsKindsSwitchIsOn() throws {
        let image = try #require(URL(string: "https://example.com/cove.jpg"))
        let video = try #require(URL(string: "https://example.com/clip.mov"))
        #expect(policy.readsAddresses, "on by default")
        #expect(policy.decide(copy(), content: { .address(image) }) == .optimiseAddress(image, copy()))
        #expect(policy.decide(copy(), content: { .address(video) }) == .ignore(.skipped(.disabled)), "copied videos are off by default")
        try EsclopSettings.optimiseVideoClipboard.set(true, in: settings.store)
        #expect(policy.decide(copy(), content: { .address(video) }) == .optimiseAddress(video, copy()))
        try EsclopSettings.enableClipboardOptimiser.set(false, in: settings.store)
        #expect(policy.decide(copy(), content: { .address(image) }) == .ignore(.skipped(.disabled)))
    }

    @Test func theSwitchAndTheClipboardRulesStillApply() throws {
        let image = try #require(URL(string: "https://example.com/cove.jpg"))
        #expect(policy.decide(copy(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), content: { .address(image) }) == .ignore(.transient))
        try EsclopSettings.clipboardIgnoredAppBundleIds.set(["com.example.vault"], in: settings.store)
        #expect(policy.decide(ClipboardCopy(changeCount: 9, app: "com.example.vault"), content: { .address(image) }) == .ignore(.ignoredApp))
        try EsclopSettings.optimiseURLClipboard.set(false, in: settings.store)
        #expect(!policy.readsAddresses)
        #expect(policy.decide(copy(), content: { .address(image) }) == .ignore(.unsupported))
    }

    @Test func theReaderTakesTheURLTypeOrTheWholeText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // Safari's Copy Link: the address as a URL, its title as text.
        pasteboard.clearContents()
        pasteboard.declareTypes([.URL, .string], owner: nil)
        pasteboard.setString("https://example.com/cove.jpg", forType: .URL)
        pasteboard.setString("A cove", forType: .string)
        #expect(ClipboardPolicy.read(pasteboard, text: false) == .address(URL(string: "https://example.com/cove.jpg")!))
        #expect(ClipboardPolicy.read(pasteboard, text: false, addresses: false) == .empty)
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/cove.jpg", forType: .string)
        #expect(ClipboardPolicy.read(pasteboard, text: false) == .address(URL(string: "https://example.com/cove.jpg")!))
        pasteboard.clearContents()
        pasteboard.setString("Look: https://example.com/cove.jpg", forType: .string)
        #expect(ClipboardPolicy.read(pasteboard) == .empty)
        // Copied pixels win over the address that comes with them.
        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)
        pasteboard.setString("https://example.com/cove.jpg", forType: .URL)
        guard case .image = ClipboardPolicy.read(pasteboard) else {
            Issue.record("expected the copied pixels")
            return
        }
    }
}

@MainActor
@Suite struct ClipboardAddressTests {
    func clipboardPaths(_ harness: Harness) -> [String]? {
        guard case let .files(urls) = Clipboard.read(harness.pasteboard) else { return nil }
        return urls.map(\.standardizedFileURL.path)
    }

    /// The person copies `address` as text; the watcher's decision on it, when it would download it.
    func copy(_ address: String, on harness: Harness) -> ClipboardCopy {
        harness.pasteboard.clearContents()
        harness.pasteboard.setString(address, forType: .string)
        return harness.copyNow()
    }

    @Test func aCopiedAddressIsDownloadedAndItsResultGoesBack() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: harness.temp.file("cove.png"))
        harness.model.download = { try fake.fetch($0) }
        let address = try #require(URL(string: "https://example.com/cove.png"))
        harness.model.handleClipboard(.optimiseAddress(address, copy(address.absoluteString, on: harness)))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        let card = try #require(harness.model.cards.first)
        #expect(fake.addresses == [address])
        #expect(card.origin == .clipboard, "a copied file's card: Copy, Save to Downloads, Save As")
        #expect(harness.requests.requests.last?.location == .temporary, "optimised as a copied file")
        let result = try #require(card.result)
        #expect(await eventually { clipboardPaths(harness) == [result.output.standardizedFileURL.path] }, "the result takes the address's place")
    }

    @Test func somethingCopiedDuringTheDownloadStays() async throws {
        let harness = Harness()
        let file = harness.temp.file("cove.png")
        let pasteboard = harness.pasteboard
        // The person copies a note while the address downloads.
        harness.model.download = { _ in
            await MainActor.run {
                pasteboard.clearContents()
                pasteboard.setString("a note", forType: .string)
            }
            return file
        }
        let address = try #require(URL(string: "https://example.com/cove.png"))
        harness.model.handleClipboard(.optimiseAddress(address, copy(address.absoluteString, on: harness)))
        #expect(await eventually { harness.model.cards.first?.result != nil })
        await harness.clipboardSettles()
        #expect(harness.pasteboard.string(forType: .string) == "a note")
    }

    @Test func aDownloadFollowsACopiedFilesRules() async throws {
        let harness = Harness()
        // Below `minImageSizeKB`, and a PDF the address did not name (`Content-Disposition`).
        for file in [harness.temp.file("icon.png", bytes: 5_000), harness.temp.file("report.pdf")] {
            let fake = FakeDownload(file: file)
            harness.model.download = { try fake.fetch($0) }
            let address = try #require(URL(string: "https://example.com/photo.png"))
            await harness.model.optimiseAddress(address, aggressive: false, automatic: true, copy: copy(address.absoluteString, on: harness), pipeline: { _ in nil })
            #expect(fake.addresses == [address])
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.model.cards.isEmpty)
        #expect(harness.requests.requests.isEmpty)
    }

    @Test func aRefusedDownloadIsSilentWhenCopied() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: nil)
        harness.model.download = { try fake.fetch($0) }
        let address = try #require(URL(string: "https://example.com/cove.jpg"))
        harness.model.handleClipboard(.optimiseAddress(address, copy(address.absoluteString, on: harness)))
        #expect(await eventually { fake.addresses == [address] })
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.addresses == [address], "tried once")
        #expect(harness.model.cards.isEmpty, "no notice")
        #expect(harness.model.recent.isEmpty)
    }

    @Test func aRefusedDownloadIsANoticeOnTheHotkey() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: nil)
        harness.model.download = { try fake.fetch($0) }
        let address = try #require(URL(string: "https://example.com/cove.jpg"))
        _ = copy(address.absoluteString, on: harness)
        await harness.model.optimiseClipboard(aggressive: false)
        let notice = try #require(harness.model.cards.first)
        #expect(notice.presentation.capsule == .notice(
            title: "Could not download the copied address",
            detail: CardPresentation.message(for: EsclopError.other("https://example.com/cove.jpg is not an image, video, PDF or audio file (text/html)"))
        ))
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.addresses == [address], "tried once")
        #expect(harness.model.recent.isEmpty)
    }

    @Test func theHotkeyDownloadsAnAddressWithTheSwitchOff() async throws {
        let harness = Harness()
        try EsclopSettings.optimiseURLClipboard.set(false, in: harness.settings.store)
        let fake = FakeDownload(file: harness.temp.png("cove.png"))
        harness.model.download = { try fake.fetch($0) }
        // Off, the watcher does not read the address at all.
        let watcher = ClipboardWatcher(pasteboard: harness.pasteboard, policy: ClipboardPolicy(factory: harness.model.factory), frontmostApp: { nil }, onAction: { _ in })
        _ = copy("https://example.com/cove.png", on: harness)
        #expect(watcher.poll() == .ignore(.empty))
        await harness.model.optimiseClipboard(aggressive: false)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(fake.addresses == [URL(string: "https://example.com/cove.png")!])
    }

    @Test func theHotkeyLeavesOtherLinksAlone() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: harness.temp.png("cove.png"))
        harness.model.download = { try fake.fetch($0) }
        _ = copy("https://example.com/login?token=abc123", on: harness)
        await harness.model.optimiseClipboard(aggressive: false)
        #expect(await eventually { harness.model.cards.first?.presentation.capsule == .notice(title: "Nothing to optimise", detail: "Copy an image or a file first.") })
        #expect(fake.addresses.isEmpty)
    }

    // MARK: Gathering results (appendClipboardResults)

    /// Files copied in Finder, as the watcher sees the copy and decides on it.
    func copy(files: [URL], on harness: Harness) async -> ClipboardAction {
        let action = harness.copy(files: files)
        let copy = harness.copyNow()
        await harness.model.clipboard.run { $0.noteCopy(copy) }
        return action
    }

    func optimise(_ file: URL, on harness: Harness) async throws -> URL {
        let count = harness.model.recent.count
        harness.model.handleClipboard(await copy(files: [file], on: harness))
        #expect(await eventually { harness.model.recent.count == count + 1 })
        let output = try #require(harness.model.recent.first { $0.source.standardizedFileURL == file.standardizedFileURL }?.output)
        #expect(await eventually { clipboardPaths(harness)?.last == output.standardizedFileURL.path })
        await harness.clipboardSettles()
        return output.standardizedFileURL
    }

    @Test func resultsGatherOnTheClipboardWhenAsked() async throws {
        let harness = Harness()
        try EsclopSettings.appendClipboardResults.set(true, in: harness.settings.store)
        let first = try await optimise(harness.temp.png("a.png"), on: harness)
        let second = try await optimise(harness.temp.png("b.png"), on: harness)
        #expect(clipboardPaths(harness) == [first.path, second.path], "one paste gives both")
        // A copy of something else in between: the next result starts again.
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("a note", forType: .string)
        let note = harness.copyNow()
        await harness.model.clipboard.run { $0.noteCopy(note) }
        let third = try await optimise(harness.temp.png("c.png"), on: harness)
        #expect(clipboardPaths(harness) == [third.path])
    }

    @Test func resultsReplaceEachOtherByDefault() async throws {
        let harness = Harness()
        _ = try await optimise(harness.temp.png("a.png"), on: harness)
        let second = try await optimise(harness.temp.png("b.png"), on: harness)
        #expect(clipboardPaths(harness) == [second.path])
    }
}

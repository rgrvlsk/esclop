// SPDX-License-Identifier: GPL-3.0-or-later
//
// A copied web address of a media file is offered for download, and nothing is fetched before
// the offer's click; with "Download and optimise" it is downloaded and optimised as a copied file
// on its own. Any other link is never fetched. With `appendClipboardResults`, results gather on
// the clipboard so one paste gives them all, for 30 seconds after the last.

import AppKit
import EsclopCore
@testable import EsclopAppKit
import EsclopIPC
import EsclopOptimisers
import Foundation
import Testing

/// A download that never touches the network: every address it is asked for, on which terms,
/// and what it gives.
final class FakeDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(url: URL, automatic: Bool, largest: Int)] = []
    let file: URL?

    /// Gives `file`, or refuses as `WebDownload` refuses a web page.
    init(file: URL?) { self.file = file }

    var addresses: [URL] { lock.withLock { asked.map(\.url) } }
    var terms: [(automatic: Bool, largest: Int)] { lock.withLock { asked.map { ($0.automatic, $0.largest) } } }

    func fetch(_ url: URL, _ terms: WebDownload.Terms = WebDownload.Terms()) throws -> URL {
        lock.withLock { asked.append((url, terms.automatic, terms.largest)) }
        guard let file else { throw WebDownload.Refusal.notMedia(url, type: "text/html") }
        return file
    }
}

/// A download that runs until it is stopped.
final class EndlessDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var wasStopped = false
    var stopped: Bool { lock.withLock { wasStopped } }

    func fetch(_ terms: WebDownload.Terms = WebDownload.Terms()) async throws -> URL {
        terms.progress(0.4)
        do {
            try await Task.sleep(for: .seconds(600))
        } catch {
            lock.withLock { wasStopped = true }
        }
        throw CancellationError()
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

    @Test func aMediaAddressIsOfferedWhenItsKindsSwitchIsOn() throws {
        let image = try #require(URL(string: "https://example.com/cove.jpg"))
        let video = try #require(URL(string: "https://example.com/clip.mov"))
        #expect(policy.readsAddresses, "offered by default")
        #expect(policy.decide(copy(), content: { .address(image) }) == .offerAddress(image, copy()))
        #expect(policy.decide(copy(), content: { .address(video) }) == .ignore(.skipped(.disabled)), "copied videos are off by default")
        try EsclopSettings.optimiseVideoClipboard.set(true, in: settings.store)
        #expect(policy.decide(copy(), content: { .address(video) }) == .offerAddress(video, copy()))
        try EsclopSettings.optimiseURLClipboard.set(.download, in: settings.store)
        #expect(policy.decide(copy(), content: { .address(video) }) == .optimiseAddress(video, copy()), "downloaded on its own when chosen")
        try EsclopSettings.enableClipboardOptimiser.set(false, in: settings.store)
        #expect(policy.decide(copy(), content: { .address(image) }) == .ignore(.skipped(.disabled)))
    }

    /// The setting was a switch before 0.2: a stored true is "Download and optimise".
    @Test func theOldSwitchReadsAsItsChoice() {
        #expect(EsclopSettings.optimiseURLClipboard.value(in: settings.store) == .offer)
        settings.store.defaults.set(true, forKey: EsclopSettings.optimiseURLClipboard.key)
        #expect(EsclopSettings.optimiseURLClipboard.value(in: settings.store) == .download)
        settings.store.defaults.set(false, forKey: EsclopSettings.optimiseURLClipboard.key)
        #expect(EsclopSettings.optimiseURLClipboard.value(in: settings.store) == .ignore)
    }

    /// This Mac and the local network are never offered nor fetched on their own, by name or
    /// address; the hotkey still fetches them.
    @Test func aLocalAddressIsLeftToTheHotkey() throws {
        try EsclopSettings.optimiseURLClipboard.set(.download, in: settings.store)
        for local in [
            "http://127.0.0.1:8080/a.png", "http://localhost/a.png", "http://192.168.1.4/a.png", "http://10.0.0.2/a.png",
            "http://172.20.0.1/a.png", "http://169.254.1.1/a.png", "http://100.64.0.1/a.png", "http://[::1]/a.png",
            "http://[fe80::1]/a.png", "http://[fd00::2]/a.png", "http://[::ffff:192.168.0.1]/a.png", "http://nas.local/a.png", "http://printer/a.png",
        ] {
            let url = try #require(URL(string: local))
            #expect(WebDownload.isLocal(url), "\(local)")
            #expect(policy.decide(copy(), content: { .address(url) }) == .ignore(.localAddress), "\(local)")
        }
        for remote in ["https://example.com/a.png", "https://203.0.113.9/a.png", "https://[2001:db8::1]/a.png", "https://172.32.0.1/a.png"] {
            #expect(!WebDownload.isLocal(try #require(URL(string: remote))), "\(remote)")
        }
    }

    @Test func theSwitchAndTheClipboardRulesStillApply() throws {
        let image = try #require(URL(string: "https://example.com/cove.jpg"))
        #expect(policy.decide(copy(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), content: { .address(image) }) == .ignore(.transient))
        try EsclopSettings.clipboardIgnoredAppBundleIds.set(["com.example.vault"], in: settings.store)
        #expect(policy.decide(ClipboardCopy(changeCount: 9, app: "com.example.vault"), content: { .address(image) }) == .ignore(.ignoredApp))
        try EsclopSettings.optimiseURLClipboard.set(.ignore, in: settings.store)
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

    /// The offer: a card with the name, the host and "Download and optimise". Nothing is fetched
    /// before the click, the clipboard is not touched, and each address is offered once.
    @Test func anOfferFetchesNothingUntilItsClick() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: harness.temp.file("cove.png"))
        harness.model.download = { try fake.fetch($0, $1) }
        let address = try #require(URL(string: "https://images.example.com/cove.png"))
        let copied = copy(address.absoluteString, on: harness)
        let shown = Date()
        harness.model.now = { shown }
        harness.model.handleClipboard(.offerAddress(address, copied))
        harness.model.now = Date.init
        let offer = try #require(harness.model.cards.first)
        #expect(offer.presentation.capsule == .notice(title: "cove.png", detail: "images.example.com"))
        #expect(offer.presentation.actions == [.download, .dismiss])
        #expect(CardPresentation.Action.download.title == "Download and optimise")
        #expect(offer.machine.hideDeadline == shown.addingTimeInterval(4), "brief")
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.addresses.isEmpty, "no request before the click")
        #expect(harness.pasteboard.changeCount == copied.changeCount, "the clipboard is not touched")
        harness.model.handleClipboard(.offerAddress(address, copied))
        #expect(harness.model.cards.count == 1, "offered once")

        harness.model.perform(.download, on: offer)
        #expect(await eventually { harness.model.cards.contains { $0.result != nil } })
        #expect(fake.addresses == [address])
        let terms = try #require(fake.terms.first)
        #expect(terms.automatic, "the stricter session, no local hosts, one at a time")
        #expect(terms.largest == EsclopSettings.maxImageSizeMB.value(in: harness.settings.store) * 1_000_000, "the copied images' size limit")
        let result = try #require(harness.model.cards.first { $0.result != nil }?.result)
        #expect(await eventually { clipboardPaths(harness) == [result.output.standardizedFileURL.path] }, "the hotkey's path: the result goes back")

        harness.model.dismiss(try #require(harness.model.cards.first))
        harness.model.handleClipboard(.offerAddress(address, copy(address.absoluteString, on: harness)))
        #expect(harness.model.cards.isEmpty, "not offered again this session")
    }

    /// From the first byte a download has a working card: "Downloading…", the share received
    /// and Stop, which stops the transfer.
    @Test func aDownloadShowsItsCardAndStops() async throws {
        let harness = Harness()
        let endless = EndlessDownload()
        harness.model.download = { _, terms in try await endless.fetch(terms) }
        let address = try #require(URL(string: "https://example.com/cove.png"))
        let request = Task { await harness.model.optimiseAddress(address, as: .asked, copy: copy(address.absoluteString, on: harness), pipeline: { _ in nil }) }
        #expect(await eventually { harness.model.cards.first?.presentation.progress == 0.4 })
        let card = try #require(harness.model.cards.first)
        #expect(card.presentation.headline == "Downloading…")
        #expect(card.presentation.caption == "cove.png")
        #expect(card.presentation.actions == [.stop])
        harness.model.perform(.stop, on: card)
        await request.value
        #expect(endless.stopped)
        #expect(harness.model.cards.isEmpty, "no notice for a download stopped on purpose")
        #expect(harness.model.recent.isEmpty)
    }

    /// A drop's web address shows the same card until it arrives; Stop stops it too.
    @Test func aDroppedAddressShowsItsCardAndStops() async throws {
        let harness = Harness()
        let endless = EndlessDownload()
        harness.model.takeDrop(
            DropIntake(addresses: [URL(string: "https://example.com/cove.jpg")!]), harder: false, keepOriginals: false, zone: nil,
            download: { _ in try await endless.fetch() }
        )
        let card = try #require(harness.model.cards.first)
        #expect(card.presentation.headline == "Downloading…" && card.presentation.caption == "cove.jpg")
        harness.model.perform(.stop, on: card)
        #expect(await eventually { endless.stopped })
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.model.cards.isEmpty)
        // One that arrives gives its place to the file's own card.
        let file = harness.temp.png("arrived.png")
        harness.model.takeDrop(DropIntake(addresses: [URL(string: "https://example.com/arrived.png")!]), harder: false, keepOriginals: false, zone: nil, download: { _ in file })
        #expect(await eventually { harness.model.cards.count == 1 && harness.model.cards[0].result != nil })
    }

    @Test func aCopiedAddressIsDownloadedAndItsResultGoesBack() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: harness.temp.file("cove.png"))
        harness.model.download = { try fake.fetch($0, $1) }
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
        // The person copies a note while the address downloads.
        harness.model.download = { _, _ in
            await MainActor.run {
                harness.pasteboard.clearContents()
                harness.pasteboard.setString("a note", forType: .string)
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
            harness.model.download = { try fake.fetch($0, $1) }
            let address = try #require(URL(string: "https://example.com/photo.png"))
            await harness.model.optimiseAddress(address, as: .automatic, copy: copy(address.absoluteString, on: harness), pipeline: { _ in nil })
            #expect(fake.addresses == [address])
            #expect(fake.terms.first?.largest == EsclopSettings.maxImageSizeMB.value(in: harness.settings.store) * 1_000_000)
            #expect(!FileManager.default.fileExists(atPath: file.path), "a refused download goes at once")
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.model.cards.isEmpty)
        #expect(harness.requests.requests.isEmpty)
    }

    @Test func aRefusedDownloadIsSilentWhenCopied() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: nil)
        harness.model.download = { try fake.fetch($0, $1) }
        let address = try #require(URL(string: "https://example.com/cove.jpg"))
        harness.model.handleClipboard(.optimiseAddress(address, copy(address.absoluteString, on: harness)))
        #expect(await eventually { fake.addresses == [address] })
        // The download's card goes in the same turn a notice would come; none comes.
        #expect(await eventually { harness.model.cards.isEmpty }, "no notice")
        #expect(fake.addresses == [address], "tried once")
        #expect(harness.model.recent.isEmpty)
    }

    @Test func aRefusedDownloadIsANoticeOnTheHotkey() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: nil)
        harness.model.download = { try fake.fetch($0, $1) }
        let address = try #require(URL(string: "https://example.com/cove.jpg"))
        _ = copy(address.absoluteString, on: harness)
        await harness.model.optimiseClipboard(aggressive: false)
        let notice = try #require(harness.model.cards.first)
        #expect(notice.presentation.capsule == .notice(title: "Could not download the copied address", detail: "It is not an image, video, PDF or audio file."))
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.addresses == [address], "tried once")
        #expect(harness.model.recent.isEmpty)
    }

    @Test func theHotkeyDownloadsAnAddressWithTheSwitchOff() async throws {
        let harness = Harness()
        try EsclopSettings.optimiseURLClipboard.set(.ignore, in: harness.settings.store)
        let fake = FakeDownload(file: harness.temp.png("cove.png"))
        harness.model.download = { try fake.fetch($0, $1) }
        // Off, the watcher does not read the address at all.
        let watcher = ClipboardWatcher(pasteboard: harness.pasteboard, policy: ClipboardPolicy(factory: harness.model.factory), frontmostApp: { nil }, onAction: { _ in })
        _ = copy("https://example.com/cove.png", on: harness)
        #expect(watcher.poll() == .ignore(.empty))
        await harness.model.optimiseClipboard(aggressive: false)
        #expect(await eventually { harness.model.cards.first?.result != nil })
        #expect(fake.addresses == [URL(string: "https://example.com/cove.png")!])
        #expect(fake.terms.first?.automatic == false && fake.terms.first?.largest == WebDownload.largest, "asked for: the default session, up to 2 GB")
    }

    /// L'Esclop's own link (an upload's) on the clipboard: the hotkey says there is nothing to
    /// optimise, instead of nothing.
    @Test func theHotkeyOnL_EsclopsOwnLinkSaysSo() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: harness.temp.png("cove.png"))
        harness.model.download = { try fake.fetch($0, $1) }
        _ = await harness.model.clipboard.run { $0.write(text: "https://uploads.example.com/cove.png", link: true) }
        await harness.model.optimiseClipboard(aggressive: false)
        #expect(harness.model.cards.first?.presentation.capsule == .notice(title: "Nothing to optimise", detail: "Copy an image or a file first."))
        #expect(fake.addresses.isEmpty)
    }

    /// Refusals are said in the person's language, without the address.
    @Test func refusalsAreSaidInCatalan() throws {
        let ca = Locale(identifier: "ca")
        let url = try #require(URL(string: "https://example.com/cove.jpg"))
        #expect(CardPresentation.message(refusal: WebDownload.Refusal.status(url, 404), locale: ca) == "El servidor ha respost amb l’error 404.")
        #expect(CardPresentation.message(refusal: WebDownload.Refusal.notMedia(url, type: "text/html"), locale: ca) == "No és cap imatge, vídeo, PDF ni fitxer d’àudio.")
        #expect(CardPresentation.message(refusal: WebDownload.Refusal.tooLarge(url, largest: 2_000_000_000), locale: ca).hasPrefix("Fa més de "))
        #expect(!CardPresentation.message(refusal: WebDownload.Refusal.local(url), locale: ca).contains("local network"))
        #expect(WebDownload.Refusal.status(url, 404).description == "https://example.com/cove.jpg answered 404", "the CLI keeps its words")
    }

    @Test func theHotkeyLeavesOtherLinksAlone() async throws {
        let harness = Harness()
        let fake = FakeDownload(file: harness.temp.png("cove.png"))
        harness.model.download = { try fake.fetch($0, $1) }
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

    /// As in Clop, gathering starts again after 30 seconds without a new result.
    @Test func gatheringEndsAfterThirtyQuietSeconds() async throws {
        let harness = Harness()
        try EsclopSettings.appendClipboardResults.set(true, in: harness.settings.store)
        _ = try await optimise(harness.temp.png("a.png"), on: harness)
        await harness.model.clipboard.run { $0.now = { Date().addingTimeInterval(31) } }
        let second = try await optimise(harness.temp.png("b.png"), on: harness)
        #expect(clipboardPaths(harness) == [second.path])
    }

    @Test func resultsReplaceEachOtherByDefault() async throws {
        let harness = Harness()
        _ = try await optimise(harness.temp.png("a.png"), on: harness)
        let second = try await optimise(harness.temp.png("b.png"), on: harness)
        #expect(clipboardPaths(harness) == [second.path])
    }
}

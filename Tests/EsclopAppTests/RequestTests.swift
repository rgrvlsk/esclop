// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import EsclopCore
import EsclopOptimisers
@testable import EsclopAppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite struct RequestFactoryTests {
    @Test func locationFollowsTheBehaviourSettingPerKind() throws {
        let settings = TestSettings()
        let factory = RequestFactory(settings: settings.store)
        #expect(factory.location(for: .image) == .inPlace)
        try EsclopSettings.optimisedVideoBehaviour.set(.sameFolder, in: settings.store)
        try EsclopSettings.optimisedPDFBehaviour.set(.specificFolder, in: settings.store)
        #expect(factory.location(for: .video) == .sameFolder)
        #expect(factory.location(for: .pdf) == .path("%d/optimised/%f"))
        let job = factory.job(for: URL(fileURLWithPath: "/tmp/a.mov"), origin: .dropZone, aggressive: true)
        #expect(job.request.location == .sameFolder)
        #expect(job.request.quality == .aggressive)
        #expect(job.operation == .optimise)
    }

    @Test func automaticOptimisationSkipsMarkedSmallLargeAndDisabled() throws {
        let settings = TestSettings()
        let temp = TempDir()
        let factory = RequestFactory(settings: settings.store)
        let image = temp.file("a.png", bytes: 100_000)
        #expect(factory.automaticSkip(for: image) == nil)
        #expect(factory.automaticSkip(for: temp.file("tiny.png", bytes: 10)) == .tooSmall)
        try EsclopSettings.maxImageSizeMB.set(1, in: settings.store)
        #expect(factory.automaticSkip(for: temp.file("big.png", bytes: 1_500_000)) == .tooLarge)
        try OptimisedMark.set(image)
        #expect(factory.automaticSkip(for: image) == .alreadyOptimised)
        #expect(factory.automaticSkip(for: temp.file("clip.mov", bytes: 300_000)) == .disabled, "videos need their own setting")
        try EsclopSettings.optimiseVideoClipboard.set(true, in: settings.store)
        #expect(factory.automaticSkip(for: temp.file("clip2.mov", bytes: 300_000)) == nil)
        #expect(factory.automaticSkip(for: temp.file("notes.txt")) == .unsupported)
    }
}

@Suite struct ClipboardPolicyTests {
    let settings = TestSettings()
    var policy: ClipboardPolicy { ClipboardPolicy(factory: RequestFactory(settings: settings.store)) }
    let png = pngData(width: 400, height: 400)
    var bigImage: ClipboardContent { .image(Data(count: 80_000), .png) }

    @Test func copiedPixelsAreOptimised() {
        #expect(policy.decide(types: ["public.png"], content: { bigImage }, frontmostApp: nil) == .optimiseImage(Data(count: 80_000), .png))
    }

    @Test func ownWritesTransientCopiesAndIgnoredAppsAreLeftAlone() throws {
        var read = false
        let content: () -> ClipboardContent = { read = true; return bigImage }
        #expect(policy.decide(types: ["public.png", Clipboard.optimisedType.rawValue], content: content, frontmostApp: nil) == .ignore(.ownWrite))
        #expect(policy.decide(types: ["public.png", "org.nspasteboard.ConcealedType"], content: content, frontmostApp: nil) == .ignore(.transient))
        try EsclopSettings.clipboardIgnoredAppBundleIds.set(["com.example.vault"], in: settings.store)
        #expect(policy.decide(types: ["public.png"], content: content, frontmostApp: "com.example.vault") == .ignore(.ignoredApp))
        try EsclopSettings.pauseAutomaticOptimisations.set(true, in: settings.store)
        #expect(policy.decide(types: ["public.png"], content: content, frontmostApp: nil) == .ignore(.paused))
        #expect(!read, "the pasteboard contents are only read once the cheap checks pass")
    }

    @Test func settingsAndLimitsApply() throws {
        #expect(policy.decide(types: [], content: { .image(Data(count: 100), .png) }, frontmostApp: nil) == .ignore(.skipped(.tooSmall)))
        try EsclopSettings.enableClipboardOptimiser.set(false, in: settings.store)
        #expect(policy.decide(types: [], content: { bigImage }, frontmostApp: nil) == .ignore(.skipped(.disabled)))
    }

    @Test func copiedFilesFollowTheirKindsSetting() throws {
        let temp = TempDir()
        let image = temp.file("a.png")
        let video = temp.file("b.mov", bytes: 300_000)
        let pdf = temp.file("c.pdf")
        #expect(policy.decide(types: [], content: { .files([image, video, pdf]) }, frontmostApp: nil) == .optimiseFiles([image]))
        try EsclopSettings.optimisePDFClipboard.set(true, in: settings.store)
        #expect(policy.decide(types: [], content: { .files([video, pdf]) }, frontmostApp: nil) == .optimiseFiles([pdf]))
        #expect(policy.decide(types: [], content: { .files([video]) }, frontmostApp: nil) == .ignore(.skipped(.disabled)))
        #expect(policy.decide(types: [], content: { .path(image) }, frontmostApp: nil) == .ignore(.unsupported), "paths need their setting")
        try EsclopSettings.optimiseImagePathClipboard.set(true, in: settings.store)
        #expect(policy.decide(types: [], content: { .path(image) }, frontmostApp: nil) == .optimiseFiles([image]))
        #expect(policy.decide(types: [], content: { .base64Image(png, .png) }, frontmostApp: nil) == .ignore(.unsupported))
    }
}

@Suite struct ClipboardWatcherTests {
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var actions: [ClipboardAction] = []
        var paused: [Bool] = []
        func add(_ action: ClipboardAction) { lock.lock(); actions.append(action); lock.unlock() }
        func pause(_ value: Bool) { lock.lock(); paused.append(value); lock.unlock() }
    }

    @Test func reactsOnceToEachChangeAndSkipsItsOwnWrites() throws {
        let settings = TestSettings()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let seen = Seen()
        let watcher = ClipboardWatcher(
            pasteboard: pasteboard, policy: ClipboardPolicy(factory: RequestFactory(settings: settings.store)),
            frontmostApp: { nil }, onPauseChange: { seen.pause($0) }, onAction: { seen.add($0) }
        )
        #expect(watcher.poll() == nil, "nothing changed yet")
        #expect(seen.paused == [false], "the pause state is reported on the first poll")

        let data = pngData(width: 300, height: 300) + Data(count: 60_000)
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        #expect(watcher.poll() == .optimiseImage(data, .png))
        #expect(watcher.poll() == nil, "the same change is handled once")

        Clipboard.write(image: data, type: .png, to: pasteboard)
        #expect(watcher.poll() == .ignore(.ownWrite))

        try EsclopSettings.pauseAutomaticOptimisations.set(true, in: settings.store)
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        #expect(watcher.poll() == .ignore(.paused))
        #expect(seen.paused == [false, true])
        #expect(seen.actions.count == 3)
    }

    @Test func timerPollsInTheBackground() async throws {
        let settings = TestSettings()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let seen = Seen()
        let watcher = ClipboardWatcher(
            pasteboard: pasteboard, policy: ClipboardPolicy(factory: RequestFactory(settings: settings.store)),
            frontmostApp: { nil }, onAction: { seen.add($0) }
        )
        watcher.start(interval: 0.05)
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        var waited = 0
        while seen.lock.withLock({ seen.actions.isEmpty }), waited < 200 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(seen.lock.withLock { seen.actions } == [.ignore(.empty)])
    }
}

@Suite struct WorkGateTests {
    @Test func letsOnlyTheLimitThroughAndHandsSlotsOver() async {
        let gate = WorkGate(limit: 2)
        await gate.acquire()
        await gate.acquire()
        #expect(await gate.inUse == 2)
        let third = Task { await gate.acquire(); return true }
        var waited = 0
        while await gate.queued == 0, waited < 400 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(await gate.queued == 1)
        await gate.release()
        #expect(await third.value)
        #expect(await gate.inUse == 2)
        await gate.release()
        await gate.release()
        #expect(await gate.inUse == 0)
    }
}

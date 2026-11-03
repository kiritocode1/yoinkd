import Foundation
import Testing
@testable import YoinksCore

struct DownloadRulesTests {
    private static let allPhases: [DownloadPhase] = [
        .queued, .extracting, .downloading, .waiting, .pausing, .paused,
        .processing, .saving, .cancelling, .completed, .failed, .cancelled
    ]

    @Test(arguments: allPhases)
    func onlyExtractionDownloadAndPreparationCountAsRunningSourceWork(_ phase: DownloadPhase) {
        #expect(phase.isSourceWorkRunning == [.extracting, .downloading, .processing].contains(phase))
    }

    @Test func sourceJobsKeepTheirSlotWhilePreparingAndSavingButDirectJobsDoNot() throws {
        for phase in [DownloadPhase.processing, .saving] {
            #expect(try job(source: true, phase: phase).occupiesSlot)
            #expect(try !job(source: false, phase: phase).occupiesSlot)
        }
        #expect(try job(source: false, phase: .downloading).occupiesSlot)
        #expect(try !job(source: true, phase: .paused).occupiesSlot)
    }

    // MARK: Scheduling

    @Test func schedulerStopsAtTheSlotLimit() throws {
        let running = try [job(phase: .downloading), job(phase: .waiting)]
        let queued = try job(phase: .queued)
        #expect((running + [queued]).nextToStart(sourceRunning: false, canStartSource: true) == nil)
        #expect((running.prefix(1) + [queued]).nextToStart(sourceRunning: false, canStartSource: true)?.id == queued.id)
    }

    @Test func onlyOneSourceJobRunsAndOnlyWhenBackgroundWorkIsAllowed() throws {
        let source = try job(source: true, phase: .queued)
        let direct = try job(source: false, phase: .queued)
        #expect([source, direct].nextToStart(sourceRunning: false, canStartSource: true)?.id == source.id)
        #expect([source, direct].nextToStart(sourceRunning: true, canStartSource: true)?.id == direct.id)
        #expect([source, direct].nextToStart(sourceRunning: false, canStartSource: false)?.id == direct.id)
        #expect([source].nextToStart(sourceRunning: true, canStartSource: true) == nil)
    }

    // MARK: Retry and resume

    @Test func retryWithoutAResumeFileStartsFromZero() throws {
        var failed = try job(phase: .failed)
        failed.attemptID = UUID()
        failed.taskIdentifier = 4
        failed.message = "Network lost"
        failed.receivedBytes = 500
        failed.expectedBytes = 1000
        failed.processedSeconds = 3
        failed.expectedSeconds = 10
        failed.resetForRetry()
        #expect(failed.phase == .queued)
        #expect(failed.attemptID == nil && failed.taskIdentifier == nil && failed.message == nil)
        #expect(failed.receivedBytes == 0 && failed.expectedBytes == nil)
        #expect(failed.processedSeconds == nil && failed.expectedSeconds == nil)
    }

    @Test func retryWithAResumeFileKeepsByteProgress() throws {
        var failed = try job(phase: .failed)
        failed.resumeFile = try MediaFileName("job.resume")
        failed.receivedBytes = 500
        failed.expectedBytes = 1000
        failed.resetForRetry()
        #expect(failed.receivedBytes == 500 && failed.expectedBytes == 1000)
        #expect(failed.resumeFile != nil)
    }

    @Test func resumeRequeuesWithoutTheOldAttempt() throws {
        var paused = try job(source: true, phase: .paused)
        paused.attemptID = UUID()
        paused.message = "Paused when yoink'd closed. Resume to continue."
        paused.requeue()
        #expect(paused.phase == .queued && paused.attemptID == nil && paused.message == nil)
    }

    // MARK: Relaunch

    @Test(arguments: [true, false])
    func savedLibraryItemCompletesTheJob(source: Bool) throws {
        var restored = try job(source: source, phase: .saving)
        restored.taskIdentifier = 9
        let file = try MediaFileName("Video.mp4")
        let cleanup = restored.reconcileAfterRelaunch(RelaunchEvidence(savedItem: .init(file: file, title: "Saved title")))
        #expect(restored.phase == .completed)
        #expect(restored.storedFile == file && restored.title == "Saved title" && restored.taskIdentifier == nil)
        #expect(cleanup == (source ? .removeSourceWork : .none))
    }

    @Test(arguments: [DownloadPhase.extracting, .downloading, .processing, .saving, .pausing])
    func interruptedSourceWorkPausesSoItCanResume(_ phase: DownloadPhase) throws {
        var restored = try job(source: true, phase: phase)
        restored.attemptID = UUID()
        let cleanup = restored.reconcileAfterRelaunch(RelaunchEvidence())
        #expect(restored.phase == .paused && restored.attemptID == nil)
        #expect(restored.message == "Paused when yoink'd closed. Resume to continue.")
        #expect(cleanup == .none)
    }

    @Test func interruptedSourceCancellationFinishesAndRemovesItsWork() throws {
        var restored = try job(source: true, phase: .cancelling)
        restored.attemptID = UUID()
        let cleanup = restored.reconcileAfterRelaunch(RelaunchEvidence())
        #expect(restored.phase == .cancelled && restored.attemptID == nil && restored.message == nil)
        #expect(cleanup == .removeSourceWork)
    }

    @Test func stagedSourceMediaIsLeftForTheSaveToFinish() throws {
        var restored = try job(source: true, phase: .saving)
        let before = restored
        #expect(restored.reconcileAfterRelaunch(RelaunchEvidence(hasStagedFile: true)) == .none)
        #expect(restored == before)
    }

    @Test func directPauseWithoutItsTaskBecomesPaused() throws {
        var restored = try job(phase: .pausing)
        restored.taskIdentifier = 3
        _ = restored.reconcileAfterRelaunch(RelaunchEvidence())
        #expect(restored.phase == .paused && restored.taskIdentifier == nil)
    }

    @Test(arguments: [DownloadPhase.downloading, .waiting, .processing, .saving])
    func directTransferWithoutItsTaskOrFileFails(_ phase: DownloadPhase) throws {
        var restored = try job(phase: phase)
        _ = restored.reconcileAfterRelaunch(RelaunchEvidence())
        #expect(restored.phase == .failed)
        #expect(restored.message == "This download was interrupted. Tap Retry to continue.")
    }

    @Test(arguments: [DownloadPhase.downloading, .pausing])
    func directTransferWithALiveTaskIsUntouched(_ phase: DownloadPhase) throws {
        var restored = try job(phase: phase)
        let before = restored
        _ = restored.reconcileAfterRelaunch(RelaunchEvidence(hasLiveTask: true))
        #expect(restored == before)
    }

    @Test(arguments: [DownloadPhase.queued, .paused, .completed, .failed, .cancelled])
    func settledJobsAreUntouched(_ phase: DownloadPhase) throws {
        for source in [true, false] {
            var restored = try job(source: source, phase: phase)
            if phase == .completed { restored.storedFile = try MediaFileName("Done.mp4") }
            let before = restored
            #expect(restored.reconcileAfterRelaunch(RelaunchEvidence()) == .none)
            #expect(restored == before)
        }
    }

    private func job(source: Bool = false, phase: DownloadPhase) throws -> DownloadJob {
        let selection = source ? SourceSelection(kind: .video, formatID: nil, quality: "Best available") : nil
        var job = DownloadJob(link: try MediaLink("https://example.com/video.mp4"), selection: selection)
        job.phase = phase
        return job
    }
}

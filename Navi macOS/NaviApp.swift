import AppKit
import Combine
import NaviKit
import Observation
import Sparkle
import SwiftUI

// MARK: - NaviApp

@main struct NaviApp: App {
    // MARK: Lifecycle

    init() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController
        _updateRequestHandler = State(initialValue: UpdateRequestHandler(updater: updaterController.updater))
    }

    // MARK: Internal

    var body: some Scene {
        WindowGroup {
            ContentView(
                authController: authController,
                extensionController: extensionController
            )
            .task {
                await updateRequestHandler.start()
            }
        }
        .defaultSize(width: 440, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }

    // MARK: Private

    @State private var authController = AuthController { url in
        NSWorkspace.shared.open(url)
    }

    @State private var extensionController = SafariExtensionStatusController()
    @State private var updateRequestHandler: UpdateRequestHandler

    private let updaterController: SPUStandardUpdaterController
}

// MARK: - CheckForUpdatesView

private struct CheckForUpdatesView: View {
    // MARK: Lifecycle

    init(updater: SPUUpdater) {
        _viewModel = State(initialValue: CheckForUpdatesViewModel(updater: updater))
    }

    // MARK: Internal

    var body: some View {
        Button("Check for Updates…", action: viewModel.updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }

    // MARK: Private

    @State private var viewModel: CheckForUpdatesViewModel
}

// MARK: - CheckForUpdatesViewModel

@Observable private final class CheckForUpdatesViewModel {
    // MARK: Lifecycle

    init(updater: SPUUpdater) {
        self.updater = updater
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    // MARK: Internal

    let updater: SPUUpdater
    var canCheckForUpdates = false

    // MARK: Private

    private var cancellable: AnyCancellable?
}

// MARK: - UpdateRequestHandler

@MainActor @Observable private final class UpdateRequestHandler {
    // MARK: Lifecycle

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    // MARK: Internal

    func start() async {
        guard !started else { return }
        started = true

        observer = DistributedNotificationCenter.default().addObserver(
            forName: UpdateRequestBridge.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runIfRequested()
            }
        }

        runIfRequested()
    }

    // MARK: Private

    private let updater: SPUUpdater
    private var started = false
    private var observer: NSObjectProtocol?

    private func runIfRequested() {
        guard UpdateRequestBridge.consumePendingCheckForUpdates() else { return }
        updater.checkForUpdates()
    }
}

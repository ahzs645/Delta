//
//  LocalMultiplayerView.swift
//  Delta
//
//  SwiftUI view for configuring and initiating DS local multiplayer sessions.
//

import SwiftUI
import MultipeerConnectivity

@available(iOS 15, *)
extension LocalMultiplayerView
{
    fileprivate class ViewModel: ObservableObject
    {
        @Published var selectedRole: LocalMultiplayerRole = .host
        @Published var selectedMode: LocalMultiplayerMode = .multiCard
        @Published var isSessionActive = false
        @Published var isConnected = false
        @Published var connectedPeerName: String?
        @Published var statusMessage: String = ""

        let gameTitle: String?
        let gameID: String?

        private var observers: [NSObjectProtocol] = []

        init(gameTitle: String?, gameID: String?)
        {
            self.gameTitle = gameTitle
            self.gameID = gameID

            let manager = LocalMultiplayerManager.shared
            self.isSessionActive = manager.isActive
            self.isConnected = manager.isConnected
            self.connectedPeerName = manager.connectedPeers.first?.displayName

            self.setupObservers()
        }

        deinit
        {
            for observer in self.observers
            {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        private func setupObservers()
        {
            let connectObserver = NotificationCenter.default.addObserver(
                forName: .localMultiplayerDidConnect, object: nil, queue: .main
            ) { [weak self] _ in
                self?.isConnected = true
                self?.connectedPeerName = LocalMultiplayerManager.shared.connectedPeers.first?.displayName
                self?.statusMessage = NSLocalizedString("Connected!", comment: "")
            }

            let disconnectObserver = NotificationCenter.default.addObserver(
                forName: .localMultiplayerDidDisconnect, object: nil, queue: .main
            ) { [weak self] _ in
                self?.isConnected = false
                self?.connectedPeerName = nil
                self?.isSessionActive = false
                self?.statusMessage = NSLocalizedString("Disconnected.", comment: "")
            }

            let peerJoinObserver = NotificationCenter.default.addObserver(
                forName: .localMultiplayerPeerDidJoin, object: nil, queue: .main
            ) { [weak self] notification in
                if let peerID = notification.userInfo?["peerID"] as? MCPeerID
                {
                    self?.connectedPeerName = peerID.displayName
                    self?.statusMessage = String(format: NSLocalizedString("%@ joined", comment: ""), peerID.displayName)
                }
            }

            self.observers = [connectObserver, disconnectObserver, peerJoinObserver]
        }

        func startSession()
        {
            LocalMultiplayerManager.shared.startSession(
                as: self.selectedRole,
                mode: self.selectedMode,
                gameTitle: self.gameTitle,
                gameID: self.gameID
            )
            self.isSessionActive = true
            self.statusMessage = self.selectedRole == .host
                ? NSLocalizedString("Waiting for players…", comment: "")
                : NSLocalizedString("Looking for host…", comment: "")
        }

        func stopSession()
        {
            LocalMultiplayerManager.shared.stopSession()
            self.isSessionActive = false
            self.isConnected = false
            self.connectedPeerName = nil
            self.statusMessage = ""
        }
    }
}

@available(iOS 15, *)
struct LocalMultiplayerView: View
{
    @StateObject
    private var viewModel: ViewModel

    private var localizedTitle: String { String(localized: "Local Multiplayer", comment: "") }

    init(gameTitle: String? = nil, gameID: String? = nil)
    {
        self._viewModel = StateObject(wrappedValue: ViewModel(gameTitle: gameTitle, gameID: gameID))
    }

    var body: some View {
        List {
            infoSection()

            if !viewModel.isSessionActive
            {
                configurationSection()
                startSection()
            }
            else
            {
                statusSection()
                stopSection()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(localizedTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    @ViewBuilder
    private func infoSection() -> some View
    {
        Section {
        } header: {
            Text("Local Multiplayer")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Play DS games locally with a nearby device using peer-to-peer connectivity. No internet connection or server required.")
                Text("")
                Text("• **Multi-Card Play**: Both devices need the same game")
                Text("• **Download Play**: Only the host needs the game")
                Text("")
                Text("Both devices must have Delta open with the same game loaded.")
            }
        }
    }

    @ViewBuilder
    private func configurationSection() -> some View
    {
        Section("Configuration") {
            Picker("Role", selection: $viewModel.selectedRole) {
                Text("Host").tag(LocalMultiplayerRole.host)
                Text("Join").tag(LocalMultiplayerRole.guest)
            }
            .pickerStyle(.segmented)

            Picker("Mode", selection: $viewModel.selectedMode) {
                Text("Multi-Card").tag(LocalMultiplayerMode.multiCard)
                Text("Download Play").tag(LocalMultiplayerMode.downloadPlay)
            }
            .pickerStyle(.segmented)

            if let gameTitle = viewModel.gameTitle
            {
                HStack {
                    Text("Game")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(gameTitle)
                        .foregroundColor(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func startSection() -> some View
    {
        Section {
            Button {
                viewModel.startSession()
            } label: {
                HStack {
                    Spacer()
                    Text(viewModel.selectedRole == .host ? "Start Hosting" : "Join Game")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func statusSection() -> some View
    {
        Section("Status") {
            HStack {
                Text("Status")
                    .foregroundColor(.secondary)
                Spacer()
                if viewModel.isConnected
                {
                    Label("Connected", systemImage: "wifi")
                        .foregroundColor(.green)
                }
                else
                {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(viewModel.statusMessage)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let peerName = viewModel.connectedPeerName
            {
                HStack {
                    Text("Connected To")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(peerName)
                        .foregroundColor(.primary)
                }
            }

            HStack {
                Text("Role")
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.selectedRole == .host ? "Host" : "Guest")
                    .foregroundColor(.primary)
            }

            HStack {
                Text("Mode")
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.selectedMode.localizedName)
                    .foregroundColor(.primary)
            }
        }
    }

    @ViewBuilder
    private func stopSection() -> some View
    {
        Section {
            Button(role: .destructive) {
                viewModel.stopSession()
            } label: {
                HStack {
                    Spacer()
                    Text("Disconnect")
                    Spacer()
                }
            }
        }
    }
}

@available(iOS 15, *)
extension LocalMultiplayerView
{
    static func makeViewController(gameTitle: String? = nil, gameID: String? = nil) -> UIHostingController<some View>
    {
        let view = LocalMultiplayerView(gameTitle: gameTitle, gameID: gameID)

        let hostingController = UIHostingController(rootView: view)
        hostingController.navigationItem.largeTitleDisplayMode = .never
        hostingController.navigationItem.title = view.localizedTitle
        return hostingController
    }
}

@available(iOS 15, *)
#Preview {
    NavigationView {
        LocalMultiplayerView(gameTitle: "Mario Kart DS", gameID: "test-id")
    }
}

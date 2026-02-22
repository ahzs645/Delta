//
//  GameViewController+LocalMultiplayer.swift
//  Delta
//
//  Extension to integrate DS local multiplayer into the game view controller.
//

import UIKit
import DeltaCore
import MelonDSDeltaCore

extension GameViewController
{
    /// Registers notification observers for local multiplayer events.
    /// Call this from the main notification setup in GameViewController.
    func registerLocalMultiplayerObservers()
    {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localMultiplayerDidConnect(with:)),
            name: .localMultiplayerDidConnect,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localMultiplayerDidDisconnect(with:)),
            name: .localMultiplayerDidDisconnect,
            object: nil
        )
    }

    /// Presents the local multiplayer setup view as a modal.
    @available(iOS 15, *)
    func showLocalMultiplayer()
    {
        guard let game = self.game as? Game else { return }

        let viewController = LocalMultiplayerView.makeViewController(
            gameTitle: game.name,
            gameID: game.identifier
        )

        let navigationController = UINavigationController(rootViewController: viewController)

        let doneButton = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.emulatorCore?.resume()
            navigationController.dismiss(animated: true)
        })
        viewController.navigationItem.rightBarButtonItem = doneButton

        self.emulatorCore?.pause()
        self.present(navigationController, animated: true)
    }

    /// Disconnects local multiplayer when the game stops.
    func disconnectLocalMultiplayerIfNeeded()
    {
        if LocalMultiplayerManager.shared.isActive
        {
            LocalMultiplayerManager.shared.stopSession()
        }
    }

    // MARK: - Notification Handlers

    @objc private func localMultiplayerDidConnect(with notification: Notification)
    {
        guard let emulatorCore else { return }

        emulatorCore.isWirelessMultiplayerActive = true
        emulatorCore.rate = 1.0 // Disable fast forward during local multiplayer

        DispatchQueue.main.async {
            let peerName = LocalMultiplayerManager.shared.connectedPeers.first?.displayName ?? "player"
            let toastView = RSTToastView(
                text: String(format: NSLocalizedString("Connected to %@", comment: ""), peerName),
                detailText: NSLocalizedString("Some features will be disabled during local multiplayer.", comment: "")
            )
            self.show(toastView, in: self.view.window, duration: 5.0)
        }
    }

    @objc private func localMultiplayerDidDisconnect(with notification: Notification)
    {
        guard let emulatorCore, emulatorCore.isWirelessMultiplayerActive else { return }

        // Only clear the flag if WFC is also not active
        if !LocalMultiplayerManager.shared.isConnected
        {
            emulatorCore.isWirelessMultiplayerActive = false
        }

        DispatchQueue.main.async {
            let toastView = RSTToastView(
                text: NSLocalizedString("Local multiplayer disconnected", comment: ""),
                detailText: nil
            )
            self.show(toastView, in: self.view.window, duration: 3.0)
        }
    }
}

//
//  LocalMultiplayerManager.swift
//  Delta
//
//  Created for DS Local Multiplayer support.
//

import Foundation
import MultipeerConnectivity
import MelonDSDeltaCore
import DeltaCore
import Combine

extension Notification.Name
{
    static let localMultiplayerDidConnect = Notification.Name("Delta.localMultiplayerDidConnect")
    static let localMultiplayerDidDisconnect = Notification.Name("Delta.localMultiplayerDidDisconnect")
    static let localMultiplayerDidReceiveData = Notification.Name("Delta.localMultiplayerDidReceiveData")
    static let localMultiplayerPeerDidJoin = Notification.Name("Delta.localMultiplayerPeerDidJoin")
    static let localMultiplayerPeerDidLeave = Notification.Name("Delta.localMultiplayerPeerDidLeave")
}

enum LocalMultiplayerMode: Int, Codable
{
    case multiCard = 0
    case downloadPlay = 1

    var localizedName: String {
        switch self {
        case .multiCard: return NSLocalizedString("Multi-Card Play", comment: "")
        case .downloadPlay: return NSLocalizedString("Download Play", comment: "")
        }
    }
}

enum LocalMultiplayerRole: Int, Codable
{
    case host = 0
    case guest = 1
}

class LocalMultiplayerManager: NSObject, ObservableObject
{
    static let shared = LocalMultiplayerManager()

    static let serviceType = "delta-ds-local" // Must be <=15 chars, lowercase alphanumeric + hyphens
    static let wifiFrameDataKey = "wifiFrameData"

    // MARK: - Published State

    @Published private(set) var isActive = false
    @Published private(set) var isConnected = false
    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var role: LocalMultiplayerRole = .host
    @Published private(set) var mode: LocalMultiplayerMode = .multiCard

    // MARK: - MultipeerConnectivity

    private var peerID: MCPeerID!
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // MARK: - Frame Relay

    /// Queue for sending WiFi frames to avoid blocking the emulation thread.
    private let sendQueue = DispatchQueue(label: "com.delta.localMultiplayer.send", qos: .userInteractive)

    /// Buffer for incoming WiFi frames from peer.
    private let frameBuffer = LocalMultiplayerFrameBuffer()

    // MARK: - Game Info

    private(set) var gameTitle: String?
    private(set) var gameID: String?

    // MARK: - Init

    private override init()
    {
        super.init()

        let displayName = UIDevice.current.name
        self.peerID = MCPeerID(displayName: displayName)
    }

    // MARK: - Session Management

    func startSession(as role: LocalMultiplayerRole, mode: LocalMultiplayerMode, gameTitle: String?, gameID: String?)
    {
        guard !self.isActive else { return }

        self.role = role
        self.mode = mode
        self.gameTitle = gameTitle
        self.gameID = gameID

        let session = MCSession(peer: self.peerID, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        self.session = session

        switch role
        {
        case .host:
            self.startAdvertising()

        case .guest:
            self.startBrowsing()
        }

        self.isActive = true
    }

    func stopSession()
    {
        self.stopAdvertising()
        self.stopBrowsing()

        self.session?.disconnect()
        self.session = nil

        self.connectedPeers = []
        self.isActive = false
        self.isConnected = false

        self.frameBuffer.reset()

        NotificationCenter.default.post(name: .localMultiplayerDidDisconnect, object: self)
    }

    // MARK: - Advertising (Host)

    private func startAdvertising()
    {
        let discoveryInfo: [String: String] = [
            "gameTitle": self.gameTitle ?? "Unknown",
            "gameID": self.gameID ?? "",
            "mode": "\(self.mode.rawValue)"
        ]

        let advertiser = MCNearbyServiceAdvertiser(
            peer: self.peerID,
            discoveryInfo: discoveryInfo,
            serviceType: LocalMultiplayerManager.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    private func stopAdvertising()
    {
        self.advertiser?.stopAdvertisingPeer()
        self.advertiser = nil
    }

    // MARK: - Browsing (Guest)

    private func startBrowsing()
    {
        let browser = MCNearbyServiceBrowser(
            peer: self.peerID,
            serviceType: LocalMultiplayerManager.serviceType
        )
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    private func stopBrowsing()
    {
        self.browser?.stopBrowsingForPeers()
        self.browser = nil
    }

    // MARK: - WiFi Frame Relay

    /// Called by MelonDS bridge when emulated WiFi hardware sends a frame.
    /// Relays the frame to the connected peer over MultipeerConnectivity.
    func sendWiFiFrame(_ frameData: Data)
    {
        guard let session = self.session, !session.connectedPeers.isEmpty else { return }

        self.sendQueue.async {
            do
            {
                try session.send(frameData, toPeers: session.connectedPeers, with: .reliable)
            }
            catch
            {
                // Use unreliable mode as fallback for time-sensitive frames
                try? session.send(frameData, toPeers: session.connectedPeers, with: .unreliable)
            }
        }
    }

    /// Reads the next received WiFi frame from the buffer.
    /// Called by MelonDS bridge when emulated WiFi hardware expects to receive a frame.
    func receiveWiFiFrame() -> Data?
    {
        return self.frameBuffer.dequeue()
    }

    /// Returns whether there are frames available to read.
    var hasReceivedFrames: Bool {
        return !self.frameBuffer.isEmpty
    }

    // MARK: - Invite Handling

    func invitePeer(_ peerID: MCPeerID)
    {
        guard let browser = self.browser, let session = self.session else { return }

        let context = try? JSONEncoder().encode([
            "mode": "\(self.mode.rawValue)",
            "gameID": self.gameID ?? ""
        ])

        browser.invitePeer(peerID, to: session, withContext: context, timeout: 30)
    }
}

// MARK: - MCSessionDelegate

extension LocalMultiplayerManager: MCSessionDelegate
{
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState)
    {
        DispatchQueue.main.async {
            switch state
            {
            case .connected:
                if !self.connectedPeers.contains(peerID)
                {
                    self.connectedPeers.append(peerID)
                }
                self.isConnected = true

                // Stop advertising/browsing once connected
                self.stopAdvertising()
                self.stopBrowsing()

                NotificationCenter.default.post(name: .localMultiplayerDidConnect, object: self)
                NotificationCenter.default.post(name: .localMultiplayerPeerDidJoin, object: self,
                                                userInfo: ["peerID": peerID])

            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
                if self.connectedPeers.isEmpty
                {
                    self.isConnected = false
                    NotificationCenter.default.post(name: .localMultiplayerDidDisconnect, object: self)
                }
                NotificationCenter.default.post(name: .localMultiplayerPeerDidLeave, object: self,
                                                userInfo: ["peerID": peerID])

            case .connecting:
                break

            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID)
    {
        // Enqueue received WiFi frame data for the emulator to consume
        self.frameBuffer.enqueue(data)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID)
    {
        // Not used for frame relay
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress)
    {
        // Not used
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?)
    {
        // Not used
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension LocalMultiplayerManager: MCNearbyServiceAdvertiserDelegate
{
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void)
    {
        // Auto-accept invitations when hosting
        invitationHandler(true, self.session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error)
    {
        print("[LocalMultiplayer] Failed to start advertising: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension LocalMultiplayerManager: MCNearbyServiceBrowserDelegate
{
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?)
    {
        // Auto-invite discovered peers that match our game
        guard let session = self.session else { return }

        let context = try? JSONEncoder().encode([
            "mode": "\(self.mode.rawValue)",
            "gameID": self.gameID ?? ""
        ])

        browser.invitePeer(peerID, to: session, withContext: context, timeout: 30)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID)
    {
        // Peer is no longer visible
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error)
    {
        print("[LocalMultiplayer] Failed to start browsing: \(error.localizedDescription)")
    }
}

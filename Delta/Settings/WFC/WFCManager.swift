//
//  WFCManager.swift
//  Delta
//
//  Created by Riley Testut on 2/21/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import MultipeerConnectivity
import DeltaCore
import MelonDSDeltaCore

private extension URL
{
#if STAGING
static let wfcServers = URL(string: "https://f000.backblazeb2.com/file/deltaemulator-staging/delta/wfc-servers.json")!
#else
static let wfcServers = URL(string: "https://cdn.altstore.io/file/deltaemulator/delta/wfc-servers.json")!
#endif
}

extension WFCManager
{
    private struct Response: Decodable
    {
        var version: Int
        var popular: [WFCServer]?
    }
}

class WFCManager
{
    static let shared = WFCManager()
    
    private let session: URLSession
    
    private var updateKnownWFCServersTask: Task<[WFCServer]?, Error>?
    
    private init()
    {
        let configuration = URLSessionConfiguration.default
        
        #if DEBUG
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        #endif
        
        self.session = URLSession(configuration: configuration)
    }
    
    @discardableResult
    func updateKnownWFCServers() -> Task<[WFCServer]?, Error>
    {
        if let task = self.updateKnownWFCServersTask
        {
            return task
        }
        
        let task = Task { [weak self] () -> [WFCServer]? in
            defer {
                self?.updateKnownWFCServersTask = nil
            }
            
            guard let self else { return nil }
            
            do
            {
                
                let (data, urlResponse) = try await self.session.data(from: .wfcServers)
                
                if let response = urlResponse as? HTTPURLResponse
                {
                    switch response.statusCode
                    {
                    case 200...299: break // OK
                    case 404: throw URLError(.fileDoesNotExist, userInfo: [NSURLErrorKey: URL.wfcServers])
                    default: throw URLError(.badServerResponse, userInfo: [NSURLErrorKey: URL.wfcServers])
                    }
                }
                
                let response = try JSONDecoder().decode(Response.self, from: data)
                UserDefaults.standard.wfcServers = response.popular
                return response.popular
            }
            catch
            {
                Logger.main.error("Failed to update known WFC servers. \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        
        self.updateKnownWFCServersTask = task
        return task
    }
    
    func resetWFCConfiguration()
    {
        Settings.preferredWFCServer = nil
        Settings.customWFCServer = nil
        
        UserDefaults.standard.removeObject(forKey: MelonDS.wfcIDUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: MelonDS.wfcFlagsUserDefaultsKey)
        
        UserDefaults.standard.didShowChooseWFCServerAlert = false
    }
}

private extension Data
{
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T)
    {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            self.append(bytes.bindMemory(to: UInt8.self))
        }
    }
    
    func integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T?
    {
        let length = MemoryLayout<T>.size
        guard offset >= 0, (offset + length) <= self.count else { return nil }
        
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { buffer in
            self.copyBytes(to: buffer, from: offset..<(offset + length))
        }
        
        return T(littleEndian: value)
    }
}

final class MelonDSLocalMultiplayerManager: NSObject
{
    static let shared = MelonDSLocalMultiplayerManager()
    
    static let didConnectNotification = Notification.Name("com.rileytestut.delta.melonds.localmultiplayer.didConnect")
    static let didDisconnectNotification = Notification.Name("com.rileytestut.delta.melonds.localmultiplayer.didDisconnect")

    struct DiagnosticsSnapshot
    {
        let localPeerIdentifier: String
        let gameHash: String?
        let connectedPeers: [String]
        let connectingPeers: [String]
        let invitedPeers: [String]
        let isTransportActive: Bool
    }
    
    private static let discoveryGameHashKey = "g"
    private static let peerIdentifierDefaultsKey = "melondsLocalMultiplayerPeerDisplayName"
    private static let serviceType = "deltamelonds"
    
    private let peerID: MCPeerID
    private let queue = DispatchQueue(label: "com.rileytestut.Delta.MelonDS.LocalMultiplayer")
    
    private weak var bridge: MelonDSEmulatorBridge?
    private var gameHash: UInt64?
    
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var packetObserver: NSObjectProtocol?
    
    private var invitedPeers = Set<String>()
    private var connectingPeers = Set<String>()
    private var connectedPeers = Set<String>()
    
    override private init()
    {
        self.peerID = Self.makePeerID()
        super.init()
    }
    
    func start(for bridge: MelonDSEmulatorBridge)
    {
        guard let gameURL = (bridge as EmulatorBridging).gameURL else {
            self.stop(for: bridge)
            return
        }
        
        let gameHash = Self.gameHash(for: gameURL)
        
        self.queue.async {
            if let activeBridge = self.bridge,
               activeBridge === bridge,
               self.gameHash == gameHash,
               self.session != nil
            {
                return
            }
            
            self.stopLocked(postDisconnect: false)
            
            self.bridge = bridge
            self.gameHash = gameHash
            Logger.main.info("LocalMP start peer=\(self.peerID.displayName, privacy: .public) hash=\(gameHash.map(Self.hexString(for:)) ?? "wildcard", privacy: .public)")
            
            let session = MCSession(peer: self.peerID, securityIdentity: nil, encryptionPreference: .none)
            session.delegate = self
            self.session = session
            
            let discoveryInfo = gameHash.map { [Self.discoveryGameHashKey: Self.hexString(for: $0)] }
            
            let advertiser = MCNearbyServiceAdvertiser(peer: self.peerID, discoveryInfo: discoveryInfo, serviceType: Self.serviceType)
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
            
            let browser = MCNearbyServiceBrowser(peer: self.peerID, serviceType: Self.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
            
            self.packetObserver = NotificationCenter.default.addObserver(forName: MelonDSEmulatorBridge.didProduceMultiplayerPacketNotification, object: bridge, queue: nil) { [weak self] notification in
                self?.handleOutboundPacket(notification)
            }
        }
    }
    
    func stop(for bridge: MelonDSEmulatorBridge? = nil)
    {
        self.queue.async {
            if let bridge, let activeBridge = self.bridge, activeBridge !== bridge
            {
                return
            }
            
            self.stopLocked(postDisconnect: true)
        }
    }

    func diagnosticsSnapshot() -> DiagnosticsSnapshot
    {
        self.queue.sync {
            DiagnosticsSnapshot(
                localPeerIdentifier: self.peerID.displayName,
                gameHash: self.gameHash.map(Self.hexString(for:)),
                connectedPeers: self.connectedPeers.sorted(),
                connectingPeers: self.connectingPeers.sorted(),
                invitedPeers: self.invitedPeers.sorted(),
                isTransportActive: (self.bridge != nil && self.session != nil)
            )
        }
    }
    
    private func stopLocked(postDisconnect: Bool)
    {
        let activeBridge = self.bridge
        let activeHash = self.gameHash.map(Self.hexString(for:)) ?? "wildcard"
        
        if let packetObserver = self.packetObserver
        {
            NotificationCenter.default.removeObserver(packetObserver)
            self.packetObserver = nil
        }
        
        self.browser?.stopBrowsingForPeers()
        self.browser?.delegate = nil
        self.browser = nil
        
        self.advertiser?.stopAdvertisingPeer()
        self.advertiser?.delegate = nil
        self.advertiser = nil
        
        self.session?.disconnect()
        self.session?.delegate = nil
        self.session = nil
        
        self.invitedPeers.removeAll()
        self.connectingPeers.removeAll()
        
        let hadConnections = !self.connectedPeers.isEmpty
        self.connectedPeers.removeAll()
        
        self.gameHash = nil
        self.bridge = nil
        
        Logger.main.info("LocalMP stop peer=\(self.peerID.displayName, privacy: .public) hash=\(activeHash, privacy: .public)")
        
        if postDisconnect && hadConnections
        {
            self.post(notification: Self.didDisconnectNotification, bridge: activeBridge)
        }
    }
    
    private func handleOutboundPacket(_ notification: Notification)
    {
        self.queue.async {
            guard let bridge = self.bridge,
                  let emittedBridge = notification.object as? MelonDSEmulatorBridge,
                  emittedBridge === bridge,
                  let session = self.session,
                  !session.connectedPeers.isEmpty,
                  let payload = notification.userInfo?["packet"] as? Data,
                  let typeNumber = notification.userInfo?["type"] as? NSNumber,
                  let type = MelonDSMultiplayerPacketType(rawValue: typeNumber.intValue),
                  let timestampNumber = notification.userInfo?["timestamp"] as? NSNumber,
                  let envelope = PacketEnvelope.encode(
                    payload: payload,
                    type: type,
                    timestamp: timestampNumber.uint64Value,
                    gameHash: self.gameHash ?? PacketEnvelope.wildcardGameHash,
                    aid: {
                        if let aidNumber = notification.userInfo?["aid"] as? NSNumber
                        {
                            return UInt16(truncatingIfNeeded: aidNumber.uint64Value)
                        }
                        
                        return 0
                    }()
                  )
            else {
                return
            }
            
            do
            {
                try session.send(envelope, toPeers: session.connectedPeers, with: .unreliable)
            }
            catch
            {
                Logger.main.error("Failed to send local multiplayer packet. \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func handleInboundPacket(_ data: Data)
    {
        guard let envelope = PacketEnvelope.decode(data),
              self.matchesEnvelopeGameHash(envelope.gameHash)
        else {
            return
        }
        
        MelonDSEmulatorBridge.enqueueMultiplayerPacket(envelope.payload, type: envelope.type, timestamp: envelope.timestamp, aid: envelope.aid)
    }
    
    private func refreshConnectedPeersLocked()
    {
        let currentlyConnected = Set(self.session?.connectedPeers.map(\.displayName) ?? [])
        let wasConnected = !self.connectedPeers.isEmpty
        let isConnected = !currentlyConnected.isEmpty
        
        self.connectedPeers = currentlyConnected
        
        if isConnected && !wasConnected
        {
            self.post(notification: Self.didConnectNotification, bridge: self.bridge)
        }
        else if !isConnected && wasConnected
        {
            self.post(notification: Self.didDisconnectNotification, bridge: self.bridge)
        }
    }
    
    private func post(notification: Notification.Name, bridge: MelonDSEmulatorBridge?)
    {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: notification, object: bridge, userInfo: nil)
        }
    }
    
    private func makeInvitationContext() -> Data?
    {
        guard let gameHash = self.gameHash else { return nil }
        let context = InvitationContext(version: 1, gameHashHex: Self.hexString(for: gameHash))
        return try? JSONEncoder().encode(context)
    }
    
    private func matchesInvitationContext(_ contextData: Data?) -> Bool
    {
        guard let gameHash = self.gameHash else {
            return true
        }
        
        guard let contextData,
              let context = try? JSONDecoder().decode(InvitationContext.self, from: contextData),
              context.version == 1,
              let invitedGameHash = UInt64(context.gameHashHex, radix: 16)
        else {
            return false
        }
        
        return invitedGameHash == gameHash
    }
    
    private func shouldInvite(_ peerID: MCPeerID, discoveryInfo: [String : String]?) -> Bool
    {
        guard peerID != self.peerID else { return false }
        guard self.matchesDiscoveryInfo(discoveryInfo) else { return false }
        guard self.gameHash != nil else { return false }
        
        let peerName = peerID.displayName
        guard !self.connectedPeers.contains(peerName),
              !self.connectingPeers.contains(peerName),
              !self.invitedPeers.contains(peerName)
        else {
            return false
        }
        
        // Deterministic tie-breaker so only one side initiates invitations.
        return self.peerID.displayName < peerName
    }
    
    private func matchesDiscoveryInfo(_ discoveryInfo: [String : String]?) -> Bool
    {
        guard let gameHash = self.gameHash else {
            return true
        }
        
        guard let advertisedGameHashString = discoveryInfo?[Self.discoveryGameHashKey] else {
            return true
        }
        
        guard let advertisedGameHash = UInt64(advertisedGameHashString, radix: 16)
        else {
            return false
        }
        
        return advertisedGameHash == gameHash
    }
    
    private func matchesEnvelopeGameHash(_ envelopeGameHash: UInt64) -> Bool
    {
        guard let gameHash = self.gameHash else {
            return true
        }
        
        return envelopeGameHash == gameHash || envelopeGameHash == PacketEnvelope.wildcardGameHash
    }
}

private extension MelonDSLocalMultiplayerManager
{
    struct InvitationContext: Codable
    {
        var version: Int
        var gameHashHex: String
    }
    
    struct PacketEnvelope
    {
        private static let magic: UInt32 = 0x4E494649 // "NIFI"
        private static let version: UInt16 = 1
        private static let headerLength = 30
        static let wildcardGameHash: UInt64 = 0
        
        var type: MelonDSMultiplayerPacketType
        var aid: UInt16
        var timestamp: UInt64
        var gameHash: UInt64
        var payload: Data
        
        static func encode(payload: Data, type: MelonDSMultiplayerPacketType, timestamp: UInt64, gameHash: UInt64, aid: UInt16) -> Data?
        {
            guard payload.count <= Int(UInt32.max) else { return nil }
            
            var data = Data()
            data.reserveCapacity(Self.headerLength + payload.count)
            data.appendInteger(Self.magic)
            data.appendInteger(Self.version)
            data.appendInteger(UInt16(type.rawValue))
            data.appendInteger(timestamp)
            data.appendInteger(gameHash)
            data.appendInteger(aid)
            data.appendInteger(UInt32(payload.count))
            data.append(payload)
            return data
        }
        
        static func decode(_ data: Data) -> PacketEnvelope?
        {
            guard let magic = data.integer(at: 0, as: UInt32.self), magic == Self.magic,
                  let version = data.integer(at: 4, as: UInt16.self), version == Self.version,
                  let rawType = data.integer(at: 6, as: UInt16.self),
                  let timestamp = data.integer(at: 8, as: UInt64.self),
                  let gameHash = data.integer(at: 16, as: UInt64.self),
                  let aid = data.integer(at: 24, as: UInt16.self),
                  let payloadLength = data.integer(at: 26, as: UInt32.self),
                  let type = MelonDSMultiplayerPacketType(rawValue: Int(rawType))
            else {
                return nil
            }
            
            let payloadOffset = Self.headerLength
            let payloadSize = Int(payloadLength)
            guard (payloadOffset + payloadSize) <= data.count else { return nil }
            
            let payload = data.subdata(in: payloadOffset..<(payloadOffset + payloadSize))
            return PacketEnvelope(type: type, aid: aid, timestamp: timestamp, gameHash: gameHash, payload: payload)
        }
    }
    
    static func makePeerID() -> MCPeerID
    {
        if let peerDisplayName = UserDefaults.standard.string(forKey: Self.peerIdentifierDefaultsKey)
        {
            return MCPeerID(displayName: peerDisplayName)
        }
        
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        let peerDisplayName = "delta-\(suffix)"
        UserDefaults.standard.set(peerDisplayName, forKey: Self.peerIdentifierDefaultsKey)
        
        return MCPeerID(displayName: peerDisplayName)
    }
    
    static func gameHash(for gameURL: URL) -> UInt64?
    {
        // Download Play runs from the DS home screen placeholder entry, so it cannot
        // be pre-filtered to the host ROM's hash.
        guard !Self.isHomeScreenGameURL(gameURL) else { return nil }
        
        var identifier = gameURL.lastPathComponent.lowercased()
        
        if let resourceValues = try? gameURL.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = resourceValues.fileSize
        {
            identifier += "|\(fileSize)"
        }
        
        var hash: UInt64 = 14_695_981_039_346_656_037
        
        for byte in identifier.utf8
        {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        
        return hash
    }
    
    static func isHomeScreenGameURL(_ gameURL: URL) -> Bool
    {
        switch gameURL.lastPathComponent.lowercased()
        {
        case "system.bios", "dsi.bios":
            return true
            
        default:
            return false
        }
    }
    
    static func hexString(for value: UInt64) -> String
    {
        return String(format: "%016llx", value)
    }
}

extension MelonDSLocalMultiplayerManager: MCNearbyServiceAdvertiserDelegate
{
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void)
    {
        self.queue.async {
            guard self.matchesInvitationContext(context),
                  let session = self.session
            else {
                Logger.main.info("LocalMP reject invite from=\(peerID.displayName, privacy: .public)")
                invitationHandler(false, nil)
                return
            }
            
            self.connectingPeers.insert(peerID.displayName)
            Logger.main.info("LocalMP accept invite from=\(peerID.displayName, privacy: .public)")
            invitationHandler(true, session)
        }
    }
}

extension MelonDSLocalMultiplayerManager: MCNearbyServiceBrowserDelegate
{
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?)
    {
        self.queue.async {
            Logger.main.info("LocalMP found peer=\(peerID.displayName, privacy: .public) advertisedHash=\(info?[Self.discoveryGameHashKey] ?? "wildcard", privacy: .public)")
            
            guard self.shouldInvite(peerID, discoveryInfo: info),
                  let session = self.session
            else {
                return
            }
            
            self.invitedPeers.insert(peerID.displayName)
            Logger.main.info("LocalMP invite peer=\(peerID.displayName, privacy: .public)")
            browser.invitePeer(peerID, to: session, withContext: self.makeInvitationContext(), timeout: 10)
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID)
    {
        self.queue.async {
            self.invitedPeers.remove(peerID.displayName)
            self.connectingPeers.remove(peerID.displayName)
        }
    }
}

extension MelonDSLocalMultiplayerManager: MCSessionDelegate
{
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState)
    {
        self.queue.async {
            let peerName = peerID.displayName
            let stateDescription: String
            
            switch state
            {
            case .connected:
                stateDescription = "connected"
                self.invitedPeers.remove(peerName)
                self.connectingPeers.remove(peerName)
                
            case .connecting:
                stateDescription = "connecting"
                self.connectingPeers.insert(peerName)
                
            case .notConnected:
                stateDescription = "notConnected"
                self.invitedPeers.remove(peerName)
                self.connectingPeers.remove(peerName)
                
            @unknown default:
                stateDescription = "unknown"
                self.invitedPeers.remove(peerName)
                self.connectingPeers.remove(peerName)
            }
            
            Logger.main.info("LocalMP session peer=\(peerName, privacy: .public) state=\(stateDescription, privacy: .public)")
            
            self.refreshConnectedPeersLocked()
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID)
    {
        self.queue.async {
            self.handleInboundPacket(data)
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID)
    {
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress)
    {
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?)
    {
    }
}

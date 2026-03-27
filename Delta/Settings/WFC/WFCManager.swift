//
//  WFCManager.swift
//  Delta
//
//  Created by Riley Testut on 2/21/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import Network
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
        let outboundReliablePacketCount: Int
        let outboundUnreliablePacketCount: Int
        let outboundSendFailureCount: Int
        let inboundForwardedPacketCount: Int
        let inboundInvalidPacketCount: Int
        let inboundHashMismatchCount: Int
        let disconnectEventCount: Int
    }
    
    private static let peerIdentifierDefaultsKey = "melondsLocalMultiplayerPeerDisplayName"
    private static let bonjourServiceType = "_deltamelonds._tcp"
    
    private let localPeerName: String
    private let queue = DispatchQueue(label: "com.rileytestut.Delta.MelonDS.LocalMultiplayer")
    
    private weak var bridge: MelonDSEmulatorBridge?
    private var gameHash: UInt64?
    
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discoveryRetryTimer: DispatchSourceTimer?
    private var packetObserver: NSObjectProtocol?
    private var sessionLifecycleObservers = [NSObjectProtocol]()
    
    private var discoveredPeerEndpoints = [String: NWEndpoint]()
    private var activeConnections = [UUID: LANPeerConnection]()
    private var peerConnections = [String: LANPeerConnection]()
    
    private var invitedPeers = Set<String>()
    private var connectingPeers = Set<String>()
    private var connectedPeers = Set<String>()
    private var localSenderID: UInt32?
    private var remoteSenderIDs = [String: UInt32]()
    private var sessionTraceBudget = 0
    private var outboundReliablePacketCount = 0
    private var outboundUnreliablePacketCount = 0
    private var outboundSendFailureCount = 0
    private var inboundForwardedPacketCount = 0
    private var inboundInvalidPacketCount = 0
    private var inboundHashMismatchCount = 0
    private var disconnectEventCount = 0
    
    override private init()
    {
        self.localPeerName = Self.makePeerName()
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
               self.listener != nil,
               self.browser != nil
            {
                return
            }
            
            self.stopLocked(postDisconnect: false)
            
            self.bridge = bridge
            self.gameHash = gameHash
            self.resetTrafficDiagnostics()
            Logger.main.info("LocalMP start peer=\(self.localPeerName, privacy: .public) hash=\(gameHash.map(Self.hexString(for:)) ?? "wildcard", privacy: .public)")
            self.recordDiagnosticEvent("start peer=\(self.localPeerName) hash=\(gameHash.map(Self.hexString(for:)) ?? "wildcard")")
            
            self.startListeningLocked(after: 0)
            self.startBrowsingLocked(after: 0.5)
            self.startDiscoveryRetryTimerLocked()
            
            self.packetObserver = NotificationCenter.default.addObserver(forName: MelonDSEmulatorBridge.didProduceMultiplayerPacketNotification, object: bridge, queue: nil) { [weak self] notification in
                self?.handleOutboundPacket(notification)
            }
            self.sessionLifecycleObservers = [
                NotificationCenter.default.addObserver(forName: MelonDSEmulatorBridge.didBeginMultiplayerSessionNotification, object: bridge, queue: nil) { [weak self] _ in
                    self?.queue.async {
                        self?.resetSessionRoutingStateLocked(reason: "begin")
                    }
                },
                NotificationCenter.default.addObserver(forName: MelonDSEmulatorBridge.didEndMultiplayerSessionNotification, object: bridge, queue: nil) { [weak self] _ in
                    self?.queue.async {
                        self?.resetSessionRoutingStateLocked(reason: "end")
                    }
                }
            ]
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
                localPeerIdentifier: self.localPeerName,
                gameHash: self.gameHash.map(Self.hexString(for:)),
                connectedPeers: self.connectedPeers.sorted(),
                connectingPeers: self.connectingPeers.sorted(),
                invitedPeers: self.invitedPeers.sorted(),
                isTransportActive: (self.bridge != nil && self.listener != nil && self.browser != nil),
                outboundReliablePacketCount: self.outboundReliablePacketCount,
                outboundUnreliablePacketCount: self.outboundUnreliablePacketCount,
                outboundSendFailureCount: self.outboundSendFailureCount,
                inboundForwardedPacketCount: self.inboundForwardedPacketCount,
                inboundInvalidPacketCount: self.inboundInvalidPacketCount,
                inboundHashMismatchCount: self.inboundHashMismatchCount,
                disconnectEventCount: self.disconnectEventCount
            )
        }
    }
    
    private func stopLocked(postDisconnect: Bool)
    {
        let activeBridge = self.bridge
        let activeHash = self.gameHash.map(Self.hexString(for:)) ?? "wildcard"
        let hadConnections = !self.connectedPeers.isEmpty
        
        if let packetObserver = self.packetObserver
        {
            NotificationCenter.default.removeObserver(packetObserver)
            self.packetObserver = nil
        }
        for observer in self.sessionLifecycleObservers
        {
            NotificationCenter.default.removeObserver(observer)
        }
        self.sessionLifecycleObservers.removeAll()
        
        self.discoveryRetryTimer?.cancel()
        self.discoveryRetryTimer = nil
        
        self.browser?.cancel()
        self.browser = nil
        
        self.listener?.cancel()
        self.listener = nil
        
        let connections = Array(self.activeConnections.values)
        self.activeConnections.removeAll()
        self.peerConnections.removeAll()
        for connection in connections
        {
            connection.cancel()
        }
        
        self.discoveredPeerEndpoints.removeAll()
        self.invitedPeers.removeAll()
        self.connectingPeers.removeAll()
        self.connectedPeers.removeAll()
        self.localSenderID = nil
        self.remoteSenderIDs.removeAll()
        MelonDSEmulatorBridge.setExpectedRemotePeerCount(0)
        
        self.gameHash = nil
        self.bridge = nil
        
        Logger.main.info("LocalMP stop peer=\(self.localPeerName, privacy: .public) hash=\(activeHash, privacy: .public)")
        self.recordDiagnosticEvent("stop peer=\(self.localPeerName) hash=\(activeHash)")
        
        if postDisconnect && hadConnections
        {
            self.post(notification: Self.didDisconnectNotification, bridge: activeBridge)
        }
    }
    
    private func startListeningLocked(after delay: TimeInterval)
    {
        self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.bridge != nil else { return }
            
            do
            {
                let listener = try NWListener(using: Self.tcpParameters(), on: .any)
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        self?.handleListenerState(state, listener: listener)
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.queue.async {
                        self?.registerConnectionLocked(connection, initiatedLocally: false, expectedPeerName: nil)
                    }
                }
                listener.service = NWListener.Service(name: self.localPeerName, type: Self.bonjourServiceType)
                
                self.listener?.cancel()
                self.listener = listener
                listener.start(queue: self.queue)
            }
            catch
            {
                Logger.main.error("LocalMP listener failed. \(error.localizedDescription, privacy: .public)")
                self.recordDiagnosticEvent("listener create failed error=\(error.localizedDescription)")
                self.startListeningLocked(after: 1.0)
            }
        }
    }
    
    private func startBrowsingLocked(after delay: TimeInterval)
    {
        self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.bridge != nil else { return }
            
            let browser = NWBrowser(for: .bonjour(type: Self.bonjourServiceType, domain: nil), using: Self.tcpParameters())
            browser.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    self?.handleBrowserState(state, browser: browser)
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.queue.async {
                    self?.handleBrowseResults(results, browser: browser)
                }
            }
            
            self.browser?.cancel()
            self.browser = browser
            browser.start(queue: self.queue)
        }
    }
    
    private func startDiscoveryRetryTimerLocked()
    {
        self.discoveryRetryTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.bridge != nil,
                  self.connectedPeers.isEmpty,
                  self.connectingPeers.isEmpty,
                  self.invitedPeers.isEmpty
            else {
                return
            }
            
            Logger.main.info("LocalMP restart browser peer=\(self.localPeerName, privacy: .public)")
            self.startBrowsingLocked(after: 0)
        }
        timer.resume()
        
        self.discoveryRetryTimer = timer
    }
    
    private func handleListenerState(_ state: NWListener.State, listener: NWListener)
    {
        guard self.listener === listener else { return }
        
        switch state
        {
        case .failed(let error):
            Logger.main.error("LocalMP listener failed. \(error.localizedDescription, privacy: .public)")
            self.recordDiagnosticEvent("listener failed error=\(error.localizedDescription)")
            self.listener?.cancel()
            self.listener = nil
            self.startListeningLocked(after: 1.0)
            
        default:
            break
        }
    }
    
    private func handleBrowserState(_ state: NWBrowser.State, browser: NWBrowser)
    {
        guard self.browser === browser else { return }
        
        switch state
        {
        case .failed(let error):
            Logger.main.error("LocalMP browse failed. \(error.localizedDescription, privacy: .public)")
            self.recordDiagnosticEvent("browser failed error=\(error.localizedDescription)")
            self.browser?.cancel()
            self.browser = nil
            self.startBrowsingLocked(after: 1.0)
            
        default:
            break
        }
    }
    
    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, browser: NWBrowser)
    {
        guard self.browser === browser else { return }
        
        var discoveredPeerEndpoints = [String: NWEndpoint]()
        
        for result in results
        {
            guard let peerName = Self.peerName(from: result.endpoint),
                  peerName != self.localPeerName
            else {
                continue
            }
            
            discoveredPeerEndpoints[peerName] = result.endpoint
            
            guard self.shouldConnect(to: peerName)
            else {
                continue
            }
            
            Logger.main.info("LocalMP found peer=\(peerName, privacy: .public)")
            self.recordDiagnosticEvent("found peer=\(peerName)")
            self.connect(to: result.endpoint, peerName: peerName)
        }
        
        self.discoveredPeerEndpoints = discoveredPeerEndpoints
    }
    
    private func shouldConnect(to peerName: String) -> Bool
    {
        guard peerName != self.localPeerName else { return false }
        guard self.peerConnections[peerName] == nil,
              !self.connectingPeers.contains(peerName),
              !self.invitedPeers.contains(peerName)
        else {
            return false
        }
        
        // Deterministic tie-breaker so only one side initiates a TCP connection.
        return self.localPeerName < peerName
    }
    
    private func connect(to endpoint: NWEndpoint, peerName: String)
    {
        self.invitedPeers.insert(peerName)
        self.connectingPeers.insert(peerName)
        Logger.main.info("LocalMP invite peer=\(peerName, privacy: .public)")
        self.recordDiagnosticEvent("connect start peer=\(peerName)")
        
        let connection = NWConnection(to: endpoint, using: Self.tcpParameters())
        self.registerConnectionLocked(connection, initiatedLocally: true, expectedPeerName: peerName)
    }
    
    private func registerConnectionLocked(_ connection: NWConnection, initiatedLocally: Bool, expectedPeerName: String?)
    {
        guard let helloPayload = self.makeHelloPayload() else {
            connection.cancel()
            return
        }
        
        self.recordDiagnosticEvent("register connection initiatedLocally=\(initiatedLocally) expectedPeer=\(expectedPeerName ?? "nil")")
        
        let peerConnection = LANPeerConnection(connection: connection, initiatedLocally: initiatedLocally, expectedPeerName: expectedPeerName, helloPayload: helloPayload, queue: self.queue)
        peerConnection.eventHandler = { [weak self] connection, event in
            self?.queue.async {
                self?.handleConnectionEvent(event, for: connection)
            }
        }
        peerConnection.frameHandler = { [weak self] connection, kind, payload in
            self?.queue.async {
                self?.handleConnectionFrame(kind, payload: payload, from: connection)
            }
        }
        
        self.activeConnections[peerConnection.id] = peerConnection
        peerConnection.start()
    }
    
    private func handleConnectionEvent(_ event: LANPeerConnection.Event, for connection: LANPeerConnection)
    {
        switch event
        {
        case .ready:
            if let expectedPeerName = connection.expectedPeerName
            {
                Logger.main.info("LocalMP session peer=\(expectedPeerName, privacy: .public) state=connecting")
                self.recordDiagnosticEvent("connection ready expectedPeer=\(expectedPeerName)")
            }
            else
            {
                self.recordDiagnosticEvent("connection ready incoming")
            }
            
        case .failed(let error):
            Logger.main.error("LocalMP socket failed. \(error.localizedDescription, privacy: .public)")
            self.recordDiagnosticEvent("connection failed peer=\(connection.remotePeerName ?? connection.expectedPeerName ?? "nil") error=\(error.localizedDescription)")
            self.cleanupConnectionLocked(connection, countDisconnect: true)
            
        case .cancelled:
            self.recordDiagnosticEvent("connection cancelled peer=\(connection.remotePeerName ?? connection.expectedPeerName ?? "nil")")
            self.cleanupConnectionLocked(connection, countDisconnect: true)
        }
    }
    
    private func handleConnectionFrame(_ kind: TransportFrame.Kind, payload: Data, from connection: LANPeerConnection)
    {
        switch kind
        {
        case .hello:
            guard let hello = try? JSONDecoder().decode(TransportHello.self, from: payload),
                  hello.version == 1
            else {
                self.recordDiagnosticEvent("hello decode failed")
                connection.cancel()
                return
            }
            
            self.handleHello(hello, from: connection)
            
        case .packet:
            guard let peerName = connection.remotePeerName else {
                self.inboundInvalidPacketCount += 1
                connection.cancel()
                return
            }
            
            self.handleInboundPacket(payload, from: peerName)
        }
    }
    
    private func handleHello(_ hello: TransportHello, from connection: LANPeerConnection)
    {
        let peerName = hello.peerName
        
        guard !peerName.isEmpty,
              peerName != self.localPeerName
        else {
            self.recordDiagnosticEvent("reject hello invalid peer=\(peerName)")
            connection.cancel()
            return
        }
        
        if let expectedPeerName = connection.expectedPeerName,
           expectedPeerName != peerName
        {
            self.recordDiagnosticEvent("reject hello expected=\(expectedPeerName) actual=\(peerName)")
            connection.cancel()
            return
        }
        
        let remoteGameHash = hello.gameHashHex.flatMap { UInt64($0, radix: 16) }
        guard self.matchesHandshakeGameHash(remoteGameHash) else {
            Logger.main.info("LocalMP reject peer=\(peerName, privacy: .public) hash=\(hello.gameHashHex ?? "wildcard", privacy: .public)")
            self.recordDiagnosticEvent("reject hello peer=\(peerName) hash=\(hello.gameHashHex ?? "wildcard")")
            connection.cancel()
            return
        }
        
        if let existingConnection = self.peerConnections[peerName],
           existingConnection !== connection
        {
            let preferredConnection = self.preferredConnection(existingConnection, candidate: connection, peerName: peerName)
            if preferredConnection === existingConnection
            {
                self.recordDiagnosticEvent("drop duplicate peer=\(peerName) keep=existing")
                connection.cancel()
                return
            }
            
            self.recordDiagnosticEvent("drop duplicate peer=\(peerName) keep=candidate")
            self.cleanupConnectionLocked(existingConnection, countDisconnect: false)
        }
        
        connection.remotePeerName = peerName
        
        self.invitedPeers.remove(peerName)
        self.connectingPeers.remove(peerName)
        self.peerConnections[peerName] = connection
        
        Logger.main.info("LocalMP session peer=\(peerName, privacy: .public) state=connected")
        self.recordDiagnosticEvent("connected peer=\(peerName) hash=\(hello.gameHashHex ?? "wildcard")")
        self.refreshConnectedPeersLocked()
    }
    
    private func preferredConnection(_ existingConnection: LANPeerConnection, candidate: LANPeerConnection, peerName: String) -> LANPeerConnection
    {
        let shouldPreferOutboundConnection = (self.localPeerName < peerName)
        
        switch (existingConnection.initiatedLocally, candidate.initiatedLocally)
        {
        case (true, false):
            return shouldPreferOutboundConnection ? existingConnection : candidate
            
        case (false, true):
            return shouldPreferOutboundConnection ? candidate : existingConnection
            
        default:
            return existingConnection.id.uuidString <= candidate.id.uuidString ? existingConnection : candidate
        }
    }
    
    private func cleanupConnectionLocked(_ connection: LANPeerConnection, countDisconnect: Bool)
    {
        let removedConnection = (self.activeConnections.removeValue(forKey: connection.id) != nil)
        
        var removedConnectedPeer = false
        if let peerName = connection.remotePeerName
        {
            if self.peerConnections[peerName] === connection
            {
                removedConnectedPeer = self.connectedPeers.contains(peerName)
                self.peerConnections.removeValue(forKey: peerName)
            }
            
            self.invitedPeers.remove(peerName)
            self.connectingPeers.remove(peerName)
        }
        else if let expectedPeerName = connection.expectedPeerName
        {
            self.invitedPeers.remove(expectedPeerName)
            self.connectingPeers.remove(expectedPeerName)
        }
        
        if removedConnectedPeer && countDisconnect
        {
            self.disconnectEventCount += 1
        }
        
        self.recordDiagnosticEvent("cleanup peer=\(connection.remotePeerName ?? connection.expectedPeerName ?? "nil") removedConnection=\(removedConnection) removedConnectedPeer=\(removedConnectedPeer) countDisconnect=\(countDisconnect)")
        
        if removedConnection
        {
            connection.cancel()
        }
        
        if removedConnection || removedConnectedPeer
        {
            self.refreshConnectedPeersLocked()
        }
    }
    
    private func matchesHandshakeGameHash(_ remoteGameHash: UInt64?) -> Bool
    {
        guard let gameHash = self.gameHash else {
            return true
        }
        
        guard let remoteGameHash else {
            return true
        }
        
        return remoteGameHash == gameHash
    }
    
    private func makeHelloPayload() -> Data?
    {
        let hello = TransportHello(version: 1, peerName: self.localPeerName, gameHashHex: self.gameHash.map(Self.hexString(for:)))
        return try? JSONEncoder().encode(hello)
    }
    
    private func handleOutboundPacket(_ notification: Notification)
    {
        self.queue.async {
            guard let bridge = self.bridge,
                  let emittedBridge = notification.object as? MelonDSEmulatorBridge,
                  emittedBridge === bridge,
                  let payload = notification.userInfo?["packet"] as? Data,
                  let typeNumber = notification.userInfo?["type"] as? NSNumber,
                  let type = MelonDSMultiplayerPacketType(rawValue: typeNumber.intValue),
                  let timestampNumber = notification.userInfo?["timestamp"] as? NSNumber
            else {
                return
            }
            
            let aid: UInt16 = {
                if let aidNumber = notification.userInfo?["aid"] as? NSNumber
                {
                    return UInt16(truncatingIfNeeded: aidNumber.uint64Value)
                }
                
                return 0
            }()
            
            let connectedPeerNames = self.connectedPeers.sorted()
            guard !connectedPeerNames.isEmpty,
                  let senderID = self.senderIDForOutboundPacket(type: type, aid: aid, connectedPeerNames: connectedPeerNames),
                  let envelope = PacketEnvelope.encode(
                    payload: payload,
                    type: type,
                    timestamp: timestampNumber.uint64Value,
                    gameHash: self.gameHash ?? PacketEnvelope.wildcardGameHash,
                    aid: aid,
                    senderID: senderID
                  )
            else {
                return
            }
            
            self.tracePacketIfNeeded(direction: "out", type: type, aid: aid, senderID: senderID, timestamp: timestampNumber.uint64Value, peerName: connectedPeerNames.first)
            
            let connections = connectedPeerNames.compactMap { self.peerConnections[$0] }
            for connection in connections
            {
                connection.sendPacket(envelope) { [weak self, weak connection] error in
                    guard let self else { return }
                    
                    self.queue.async {
                        guard let connection else { return }
                        
                        if let error
                        {
                            self.outboundSendFailureCount += 1
                            Logger.main.error("Failed to send local multiplayer packet. \(error.localizedDescription, privacy: .public)")
                            self.cleanupConnectionLocked(connection, countDisconnect: true)
                            return
                        }
                        
                        self.outboundReliablePacketCount += 1
                    }
                }
            }
        }
    }
    
    private func handleInboundPacket(_ data: Data, from peerName: String)
    {
        guard let envelope = PacketEnvelope.decode(data)
        else {
            self.inboundInvalidPacketCount += 1
            return
        }
        
        guard self.matchesEnvelopeGameHash(envelope.gameHash)
        else {
            self.inboundHashMismatchCount += 1
            return
        }
        
        self.tracePacketIfNeeded(direction: "in", type: envelope.type, aid: envelope.aid, senderID: envelope.senderID, timestamp: envelope.timestamp, peerName: peerName)
        self.recordInboundPacketMetadata(envelope, from: peerName)
        self.inboundForwardedPacketCount += 1
        
        MelonDSEmulatorBridge.enqueueMultiplayerPacket(envelope.payload, type: envelope.type, timestamp: envelope.timestamp, aid: envelope.aid, senderID: envelope.senderID)
    }
    
    private func refreshConnectedPeersLocked()
    {
        let currentlyConnected = Set(self.peerConnections.keys)
        let wasConnected = !self.connectedPeers.isEmpty
        let isConnected = !currentlyConnected.isEmpty
        
        self.connectedPeers = currentlyConnected
        self.remoteSenderIDs = self.remoteSenderIDs.filter { currentlyConnected.contains($0.key) }
        if currentlyConnected.isEmpty
        {
            self.localSenderID = nil
        }
        
        MelonDSEmulatorBridge.setExpectedRemotePeerCount(UInt16(currentlyConnected.count))
        
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
    
    private func resetTrafficDiagnostics()
    {
        self.outboundReliablePacketCount = 0
        self.outboundUnreliablePacketCount = 0
        self.outboundSendFailureCount = 0
        self.inboundForwardedPacketCount = 0
        self.inboundInvalidPacketCount = 0
        self.inboundHashMismatchCount = 0
        self.disconnectEventCount = 0
    }

    private func resetSessionRoutingStateLocked(reason: String)
    {
        self.localSenderID = nil
        self.remoteSenderIDs.removeAll()
        self.sessionTraceBudget = 24
        MelonDSEmulatorBridge.setExpectedRemotePeerCount(UInt16(self.connectedPeers.count))
        self.recordDiagnosticEvent("session reset reason=\(reason) connectedPeers=\(self.connectedPeers.count)")
    }

    private func tracePacketIfNeeded(direction: String, type: MelonDSMultiplayerPacketType, aid: UInt16, senderID: UInt32, timestamp: UInt64, peerName: String?)
    {
        guard self.sessionTraceBudget > 0 else { return }

        self.sessionTraceBudget -= 1
        self.recordDiagnosticEvent("trace dir=\(direction) type=\(type.rawValue) aid=\(aid) sender=\(senderID) ts=\(timestamp) peer=\(peerName ?? "-")")
    }
    
    private func recordDiagnosticEvent(_ message: String)
    {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let logURL = cachesDirectory.appendingPathComponent("localmp.log")
        
        let existingData = (try? Data(contentsOf: logURL)) ?? Data()
        var updatedData = existingData
        updatedData.append(line.data(using: .utf8) ?? Data())
        
        let maxBytes = 32 * 1024
        if updatedData.count > maxBytes
        {
            updatedData = updatedData.suffix(maxBytes)
        }
        
        try? updatedData.write(to: logURL, options: .atomic)
    }
    
    private func matchesEnvelopeGameHash(_ envelopeGameHash: UInt64) -> Bool
    {
        guard let gameHash = self.gameHash else {
            return true
        }
        
        return envelopeGameHash == gameHash || envelopeGameHash == PacketEnvelope.wildcardGameHash
    }
    
    private func senderIDForOutboundPacket(type: MelonDSMultiplayerPacketType, aid: UInt16, connectedPeerNames: [String]) -> UInt32?
    {
        switch type
        {
        case .command:
            self.localSenderID = 0
            self.assignRemoteSenderIDsIfNeeded(for: connectedPeerNames)
            return 0
            
        case .reply:
            if aid > 0
            {
                let senderID = UInt32(aid)
                self.localSenderID = senderID
                
                if connectedPeerNames.count == 1, let peerName = connectedPeerNames.first, self.remoteSenderIDs[peerName] == nil
                {
                    self.remoteSenderIDs[peerName] = 0
                }
                
                return senderID
            }
            
        case .regular, .ack:
            break
            
        @unknown default:
            break
        }
        
        if let localSenderID = self.localSenderID
        {
            return localSenderID
        }
        
        if aid > 0
        {
            let senderID = UInt32(aid)
            self.localSenderID = senderID
            return senderID
        }
        
        if connectedPeerNames.count == 1,
           let peerName = connectedPeerNames.first,
           let remoteSenderID = self.remoteSenderIDs[peerName],
           remoteSenderID == 0
        {
            self.localSenderID = 1
            return 1
        }
        
        return 0
    }
    
    private func recordInboundPacketMetadata(_ envelope: PacketEnvelope, from peerName: String)
    {
        switch envelope.type
        {
        case .command:
            self.remoteSenderIDs[peerName] = envelope.senderID
            
            if self.localSenderID == nil && self.connectedPeers.count <= 1
            {
                self.localSenderID = 1
            }
            
        case .reply:
            if envelope.senderID != 0
            {
                self.remoteSenderIDs[peerName] = envelope.senderID
            }
            else if envelope.aid > 0
            {
                self.remoteSenderIDs[peerName] = UInt32(envelope.aid)
            }
            
        case .regular, .ack:
            if envelope.senderID != 0
            {
                self.remoteSenderIDs[peerName] = envelope.senderID
            }
            
        @unknown default:
            if envelope.senderID != 0
            {
                self.remoteSenderIDs[peerName] = envelope.senderID
            }
        }
        
        if self.localSenderID == nil,
           self.connectedPeers.count == 1,
           let remoteSenderID = self.remoteSenderIDs[peerName],
           remoteSenderID == 0
        {
            self.localSenderID = 1
        }
    }
    
    private func assignRemoteSenderIDsIfNeeded(for peerNames: [String])
    {
        guard self.localSenderID == 0 else { return }
        
        var nextSenderID = (self.remoteSenderIDs.values.max() ?? 0) + 1
        for peerName in peerNames.sorted() where self.remoteSenderIDs[peerName] == nil
        {
            self.remoteSenderIDs[peerName] = nextSenderID
            nextSenderID += 1
        }
    }
}

private extension MelonDSLocalMultiplayerManager
{
    struct TransportHello: Codable
    {
        var version: Int
        var peerName: String
        var gameHashHex: String?
    }
    
    struct TransportFrame
    {
        enum Kind: UInt8
        {
            case hello = 1
            case packet = 2
        }
        
        enum DecodeError: Error
        {
            case invalidData
        }
        
        private static let magic: UInt32 = 0x4C4D5032 // "LMP2"
        private static let headerLength = 9
        
        static func encode(kind: Kind, payload: Data) -> Data
        {
            var data = Data()
            data.reserveCapacity(Self.headerLength + payload.count)
            data.appendInteger(Self.magic)
            data.appendInteger(kind.rawValue)
            data.appendInteger(UInt32(payload.count))
            data.append(payload)
            return data
        }
        
        static func decodeFrames(from buffer: inout Data) throws -> [(Kind, Data)]
        {
            var frames = [(Kind, Data)]()
            
            while buffer.count >= Self.headerLength
            {
                guard let magic = buffer.integer(at: 0, as: UInt32.self), magic == Self.magic,
                      let rawKind = buffer.integer(at: 4, as: UInt8.self),
                      let kind = Kind(rawValue: rawKind),
                      let payloadLength = buffer.integer(at: 5, as: UInt32.self)
                else {
                    throw DecodeError.invalidData
                }
                
                let frameLength = Self.headerLength + Int(payloadLength)
                guard buffer.count >= frameLength else { break }
                
                let payload = buffer.subdata(in: Self.headerLength..<frameLength)
                frames.append((kind, payload))
                buffer.removeSubrange(0..<frameLength)
            }
            
            return frames
        }
    }
    
    struct PacketEnvelope
    {
        private static let magic: UInt32 = 0x4E494649 // "NIFI"
        private static let version: UInt16 = 2
        private static let legacyHeaderLength = 30
        private static let headerLength = 34
        static let wildcardGameHash: UInt64 = 0
        
        var type: MelonDSMultiplayerPacketType
        var aid: UInt16
        var senderID: UInt32
        var timestamp: UInt64
        var gameHash: UInt64
        var payload: Data
        
        static func encode(payload: Data, type: MelonDSMultiplayerPacketType, timestamp: UInt64, gameHash: UInt64, aid: UInt16, senderID: UInt32) -> Data?
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
            data.appendInteger(senderID)
            data.appendInteger(UInt32(payload.count))
            data.append(payload)
            return data
        }
        
        static func decode(_ data: Data) -> PacketEnvelope?
        {
            guard let magic = data.integer(at: 0, as: UInt32.self), magic == Self.magic,
                  let version = data.integer(at: 4, as: UInt16.self),
                  let rawType = data.integer(at: 6, as: UInt16.self),
                  let timestamp = data.integer(at: 8, as: UInt64.self),
                  let gameHash = data.integer(at: 16, as: UInt64.self),
                  let aid = data.integer(at: 24, as: UInt16.self),
                  let type = MelonDSMultiplayerPacketType(rawValue: Int(rawType))
            else {
                return nil
            }
            
            let senderID: UInt32
            let payloadOffset: Int
            let payloadLength: UInt32
            
            switch version
            {
            case 1:
                guard let decodedPayloadLength = data.integer(at: 26, as: UInt32.self)
                else {
                    return nil
                }
                
                senderID = 0
                payloadOffset = Self.legacyHeaderLength
                payloadLength = decodedPayloadLength
                
            case Self.version:
                guard let decodedSenderID = data.integer(at: 26, as: UInt32.self),
                      let decodedPayloadLength = data.integer(at: 30, as: UInt32.self)
                else {
                    return nil
                }
                
                senderID = decodedSenderID
                payloadOffset = Self.headerLength
                payloadLength = decodedPayloadLength
                
            default:
                return nil
            }
            
            let payloadSize = Int(payloadLength)
            guard (payloadOffset + payloadSize) <= data.count else { return nil }
            
            let payload = data.subdata(in: payloadOffset..<(payloadOffset + payloadSize))
            return PacketEnvelope(type: type, aid: aid, senderID: senderID, timestamp: timestamp, gameHash: gameHash, payload: payload)
        }
    }
    
    static func makePeerName() -> String
    {
        if let peerDisplayName = UserDefaults.standard.string(forKey: Self.peerIdentifierDefaultsKey)
        {
            return peerDisplayName
        }
        
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        let peerDisplayName = "delta-\(suffix)"
        UserDefaults.standard.set(peerDisplayName, forKey: Self.peerIdentifierDefaultsKey)
        
        return peerDisplayName
    }
    
    static func peerName(from endpoint: NWEndpoint) -> String?
    {
        switch endpoint
        {
        case let .service(name: name, type: _, domain: _, interface: _):
            return name
            
        default:
            return nil
        }
    }
    
    static func tcpParameters() -> NWParameters
    {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        #if targetEnvironment(simulator)
        // Simulator AWDL peer-to-peer discovery is unreliable for local testing.
        // Force standard LAN Bonjour so two booted simulators on the same Mac can
        // talk over the shared host network instead of the broken AWDL path.
        parameters.includePeerToPeer = false
        #else
        parameters.includePeerToPeer = true
        #endif
        parameters.allowLocalEndpointReuse = true
        return parameters
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
        let lastPathComponent = gameURL.lastPathComponent.lowercased()
        if gameURL.pathExtension.lowercased() == "bios"
        {
            return true
        }
        
        switch lastPathComponent
        {
        case "system.bios",
             "nds.bios",
             "dsi.bios",
             Game.melonDSBIOSIdentifier.lowercased(),
             Game.melonDSDSiBIOSIdentifier.lowercased():
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

private final class LANPeerConnection
{
    enum Event
    {
        case ready
        case failed(Error)
        case cancelled
    }
    
    let id = UUID()
    let connection: NWConnection
    let initiatedLocally: Bool
    let expectedPeerName: String?
    
    var remotePeerName: String?
    
    private let helloPayload: Data
    private let queue: DispatchQueue
    private var receiveBuffer = Data()
    private var hasSentHello = false
    
    var eventHandler: ((LANPeerConnection, Event) -> Void)?
    var frameHandler: ((LANPeerConnection, MelonDSLocalMultiplayerManager.TransportFrame.Kind, Data) -> Void)?
    
    init(connection: NWConnection, initiatedLocally: Bool, expectedPeerName: String?, helloPayload: Data, queue: DispatchQueue)
    {
        self.connection = connection
        self.initiatedLocally = initiatedLocally
        self.expectedPeerName = expectedPeerName
        self.helloPayload = helloPayload
        self.queue = queue
    }
    
    func start()
    {
        self.connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        self.connection.start(queue: self.queue)
    }
    
    func cancel()
    {
        self.connection.cancel()
    }
    
    func sendPacket(_ payload: Data, completion: @escaping (Error?) -> Void)
    {
        self.send(kind: .packet, payload: payload, completion: completion)
    }
    
    private func sendHelloIfNeeded()
    {
        guard !self.hasSentHello else { return }
        
        self.hasSentHello = true
        self.send(kind: .hello, payload: self.helloPayload) { _ in }
    }
    
    private func send(kind: MelonDSLocalMultiplayerManager.TransportFrame.Kind, payload: Data, completion: @escaping (Error?) -> Void)
    {
        let frame = MelonDSLocalMultiplayerManager.TransportFrame.encode(kind: kind, payload: payload)
        self.connection.send(content: frame, completion: .contentProcessed { error in
            completion(error)
        })
    }
    
    private func handleState(_ state: NWConnection.State)
    {
        switch state
        {
        case .ready:
            self.sendHelloIfNeeded()
            self.receiveNextChunk()
            self.eventHandler?(self, .ready)
            
        case .failed(let error):
            self.eventHandler?(self, .failed(error))
            
        case .cancelled:
            self.eventHandler?(self, .cancelled)
            
        default:
            break
        }
    }
    
    private func receiveNextChunk()
    {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if let data, !data.isEmpty
            {
                self.receiveBuffer.append(data)
                
                do
                {
                    let frames = try MelonDSLocalMultiplayerManager.TransportFrame.decodeFrames(from: &self.receiveBuffer)
                    for (kind, payload) in frames
                    {
                        self.frameHandler?(self, kind, payload)
                    }
                }
                catch
                {
                    self.connection.cancel()
                    return
                }
            }
            
            if let error
            {
                self.eventHandler?(self, .failed(error))
                return
            }
            
            guard !isComplete else {
                self.connection.cancel()
                return
            }
            
            self.receiveNextChunk()
        }
    }
}

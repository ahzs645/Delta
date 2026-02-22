//
//  LocalMultiplayerFrameBuffer.swift
//  Delta
//
//  Thread-safe ring buffer for WiFi frame relay between peers.
//

import Foundation

/// A lock-free, thread-safe FIFO buffer for relaying emulated WiFi frames
/// between the MultipeerConnectivity receive callback and the MelonDS emulation thread.
class LocalMultiplayerFrameBuffer
{
    private let lock = NSLock()
    private var buffer: [Data] = []

    /// Maximum number of frames to buffer before dropping oldest frames.
    /// DS local wireless typically sends small frames at ~60Hz, so 256 is generous.
    private let maxCapacity = 256

    var isEmpty: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.buffer.isEmpty
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.buffer.count
    }

    func enqueue(_ data: Data)
    {
        self.lock.lock()
        defer { self.lock.unlock() }

        // Drop oldest frames if buffer is full to prevent unbounded growth
        if self.buffer.count >= self.maxCapacity
        {
            self.buffer.removeFirst()
        }

        self.buffer.append(data)
    }

    func dequeue() -> Data?
    {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.buffer.isEmpty else { return nil }
        return self.buffer.removeFirst()
    }

    func reset()
    {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.buffer.removeAll()
    }
}

//
//  HelperManager.swift
//  Awayke
//

import Foundation
import os
import ServiceManagement
import AppKit

enum HelperState: Equatable {
    case notRegistered
    case awaitingApproval
    case enabled
    case notFound
}

enum HelperError: LocalizedError {
    case helperUnavailable
    case connectionFailed(String)
    case remoteError(Error)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "Awayke's privileged helper isn't approved yet."
        case .connectionFailed(let detail):
            return "Couldn't connect to Awayke's helper: \(detail)"
        case .remoteError(let underlying):
            return underlying.localizedDescription
        }
    }
}

/// Ensures a continuation is resumed exactly once when several completion
/// paths race (reply, XPC error handler, timeout).
private final class ResumeGuard {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

final class HelperManager {

    static let shared = HelperManager()

    private static let plistName = "daemonphantom.Awayke.Helper.plist"
    private static let machServiceName = "daemonphantom.Awayke.Helper"

    private let service: SMAppService
    private var connection: NSXPCConnection?

    private init() {
        self.service = SMAppService.daemon(plistName: Self.plistName)
    }

    var state: HelperState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .awaitingApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    var isUsable: Bool { state == .enabled }

    /// Idempotent. Calling on a fresh install triggers the OS approval flow
    /// and surfaces the helper in System Settings → Login Items.
    func register() {
        do {
            try service.register()
        } catch {
            NSLog("Awayke: SMAppService.register() failed: \((error as NSError).localizedDescription)")
        }
    }

    func revealInSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func unregister() {
        do {
            try service.unregister()
        } catch {
            NSLog("Awayke: SMAppService.unregister() failed: \((error as NSError).localizedDescription)")
        }
    }

    func setSleepDisabled(_ disable: Bool) async throws {
        try await performCall { proxy, reply in proxy.setSleepDisabled(disable, reply: reply) }
    }

    func sleepNow() async throws {
        try await performCall { proxy, reply in proxy.sleepNow(reply: reply) }
    }

    /// Runs one XPC call with a reply timeout. Without the timeout a call
    /// can hang forever: if the daemon registration went stale (the app
    /// bundle was replaced in place), launchd retries spawning the helper
    /// indefinitely and the message stays queued, so neither the reply nor
    /// the error handler ever fires. A connection-level failure also
    /// triggers re-registration against the current bundle.
    private func performCall(_ invoke: @escaping (AwaykeHelperProtocol, @escaping (NSError?) -> Void) -> Void) async throws {
        guard isUsable else { throw HelperError.helperUnavailable }

        let conn = connection ?? makeConnection()
        connection = conn

        let resumed = ResumeGuard()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                func finish(_ result: Result<Void, Error>) {
                    guard resumed.claim() else { return }
                    continuation.resume(with: result)
                }

                guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                    finish(.failure(HelperError.connectionFailed(error.localizedDescription)))
                }) as? AwaykeHelperProtocol else {
                    finish(.failure(HelperError.connectionFailed("Couldn't cast remote proxy to AwaykeHelperProtocol")))
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    finish(.failure(HelperError.connectionFailed("helper didn't reply within 5s")))
                }

                invoke(proxy) { remoteError in
                    if let remoteError {
                        finish(.failure(HelperError.remoteError(remoteError)))
                    } else {
                        finish(.success(()))
                    }
                }
            }
        } catch {
            if case HelperError.connectionFailed = error {
                repairRegistration()
            }
            throw error
        }
    }

    /// A stale registration survives app-bundle replacement and leaves
    /// launchd unable to spawn the helper ("Could not find and/or execute
    /// program specified by service"). Unregister + register points launchd
    /// back at the current bundle.
    private func repairRegistration() {
        Log.power.error("helper connection failed — re-registering daemon")
        connection?.invalidate()
        connection = nil
        do {
            try service.unregister()
        } catch {
            Log.power.error("unregister during repair failed: \(error.localizedDescription, privacy: .public)")
        }
        register()
    }

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: AwaykeHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        conn.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        conn.resume()
        return conn
    }
}

//
//  PowerManager.swift
//  Awayke
//
//  Toggles `pmset -a disablesleep` via the helper when approved, or via
//  osascript with admin privileges as a fallback.
//

import Foundation
import os

enum PowerManagerError: LocalizedError {
    case scriptFailed(status: Int32, message: String)
    case launchFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let status, let message):
            if message.isEmpty { return "pmset failed (exit \(status))." }
            return "pmset failed (exit \(status)): \(message)"
        case .launchFailed(let error):
            return "Couldn't launch osascript: \(error.localizedDescription)"
        }
    }
}

final class PowerManager {

    private let helper: HelperManager

    init(helper: HelperManager = .shared) {
        self.helper = helper
    }

    func disableSleep(_ disable: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        if helper.isUsable {
            Task {
                do {
                    try await helper.setSleepDisabled(disable)
                    Log.power.log("disablesleep=\(disable ? 1 : 0) set via helper")
                    completion(.success(()))
                } catch {
                    Log.power.error("helper setSleepDisabled failed: \(error.localizedDescription, privacy: .public) — falling back to osascript")
                    self.disableSleepViaOsascript(disable, completion: completion)
                }
            }
        } else {
            Log.power.log("helper not usable (state not enabled) — using osascript for disablesleep=\(disable ? 1 : 0)")
            disableSleepViaOsascript(disable, completion: completion)
        }
    }

    /// Forces immediate sleep. Needed after re-enabling sleep with the lid
    /// closed: clearing `disablesleep` doesn't re-trigger clamshell sleep,
    /// so without this the machine stays awake until the next lid event.
    func sleepNow() {
        if helper.isUsable {
            Task {
                do {
                    try await helper.sleepNow()
                    Log.power.log("sleepnow issued via helper")
                } catch {
                    Log.power.error("helper sleepNow failed: \(error.localizedDescription, privacy: .public) — trying pmset directly")
                    self.sleepNowDirect()
                }
            }
        } else {
            sleepNowDirect()
        }
    }

    private func sleepNowDirect() {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            do {
                try process.run()
                process.waitUntilExit()
                Log.power.log("pmset sleepnow (direct) exit=\(process.terminationStatus)")
            } catch {
                Log.power.error("couldn't launch pmset sleepnow: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func disableSleepViaOsascript(_ disable: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let flag = disable ? "1" : "0"
        let shellCommand = "/usr/bin/pmset -a disablesleep \(flag)"
        let appleScript = "do shell script \"\(shellCommand)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
            } catch {
                completion(.failure(PowerManagerError.launchFailed(underlying: error)))
                return
            }

            process.waitUntilExit()

            if process.terminationStatus == 0 {
                completion(.success(()))
                return
            }

            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(.failure(PowerManagerError.scriptFailed(
                status: process.terminationStatus,
                message: message
            )))
        }
    }
}

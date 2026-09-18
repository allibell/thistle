import Foundation
import SwiftUI
import UIKit

struct PerformanceEvent: Codable, Sendable {
    let id: String
    let session: String
    let at: Double
    let build: String
    let os: String
    let screen: String
    let name: String
    let milliseconds: Double
}

// No food descriptions, typed characters, API payloads, URLs, or user identifiers.
@MainActor
final class PerformanceDiagnostics {
    static let shared = PerformanceDiagnostics()
    let sessionID = UUID().uuidString.lowercased()
    private let transport = DiagnosticsTransport()
    private var currentScreen = "launch"
    private var active = false
    private var heartbeat: Timer?
    private var uploadTimer: Timer?
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    private var lastInputSample = 0.0
    private let build = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"))"

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        heartbeat?.invalidate(); uploadTimer?.invalidate()
        lastBeat = ProcessInfo.processInfo.systemUptime
        record(value ? "foreground" : "background")
        if value {
            heartbeat = Timer.scheduledTimer(withTimeInterval:0.25, repeats:true) { _ in
                MainActor.assumeIsolated { Self.shared.beat() }
            }
            uploadTimer = Timer.scheduledTimer(withTimeInterval:30, repeats:true) { _ in
                MainActor.assumeIsolated { Self.shared.flush() }
            }
        }
        flush()
    }
    private func beat() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = (now - lastBeat - 0.25) * 1000
        lastBeat = now
        if active && delay > 150 { record("main_thread_delay", milliseconds:delay) }
    }
    func screen(_ value: String) { currentScreen = value; record("screen_open") }
    func record(_ name: String, milliseconds: Double = 0) {
        let event = PerformanceEvent(id:UUID().uuidString.lowercased(), session:sessionID,
            at:Date().timeIntervalSince1970, build:build, os:UIDevice.current.systemVersion,
            screen:currentScreen, name:name, milliseconds:max(0,milliseconds))
        Task { await transport.append(event) }
    }
    func input(_ field: String) {
        let start = ProcessInfo.processInfo.systemUptime
        guard start - lastInputSample >= 2 else { return }
        lastInputSample = start
        DispatchQueue.main.async {
            self.record("input_" + field, milliseconds:(ProcessInfo.processInfo.systemUptime-start)*1000)
        }
    }
    func flush() { Task { await transport.upload() } }
}

actor DiagnosticsTransport {
    private struct Config: Codable { let endpoint: String; let token: String }
    private struct Batch: Codable { let events: [PerformanceEvent] }
    private let folder: URL
    private var events: [PerformanceEvent]
    private var uploading = false
    init() {
        folder = FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask).first!
            .appendingPathComponent("ThistleData",isDirectory:true)
        events = (try? JSONDecoder().decode([PerformanceEvent].self,
            from:Data(contentsOf:folder.appendingPathComponent("performance-events.json")))) ?? []
    }
    func append(_ event:PerformanceEvent) {
        events.removeAll { $0.at < Date().timeIntervalSince1970 - 29*86400 }
        events.append(event)
        if events.count > 2000 { events.removeFirst(events.count-2000) }
        persist()
    }
    private func persist() {
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to:folder.appendingPathComponent("performance-events.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    func upload() async {
        events.removeAll { $0.at < Date().timeIntervalSince1970 - 29*86400 }
        guard !uploading, !events.isEmpty,
            let data = try? Data(contentsOf:folder.appendingPathComponent("diagnostics-config.json")),
            let config = try? JSONDecoder().decode(Config.self,from:data),
            let url = URL(string:config.endpoint),
            (url.scheme == "https" || (url.scheme == "http" && url.host?.hasSuffix(".ts.net") == true)),
            !config.token.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        // Bounded per attempt. A failed upload remains on disk for the next foreground/timer.
        for _ in 0..<4 {
            guard !events.isEmpty else { break }
            let batch = Array(events.prefix(100))
            var request = URLRequest(url:url,timeoutInterval:10)
            request.httpMethod="POST"
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue("Bearer " + config.token,forHTTPHeaderField:"Authorization")
            request.httpBody = try? JSONEncoder().encode(Batch(events:batch))
            do {
                let (_,response) = try await URLSession.shared.data(for:request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 201 else { break }
                let sent = Set(batch.map(\.id)); events.removeAll { sent.contains($0.id) }; persist()
            } catch { break }
        }
    }
}

struct PerformanceDiagnosticsView: View {
    var body: some View {
        Section("Performance diagnostics") {
            LabeledContent("Build",value:"\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") ?? "?"))")
            Text("Session: \(PerformanceDiagnostics.shared.sessionID)").font(.caption).textSelection(.enabled)
            Text("Records screen names, operation timings and main-thread delays locally. When configured, uploads to your private Y-wing server over Tailscale. Food text and keystrokes are excluded.").font(.caption)
            Button("Mark this session as slow") { PerformanceDiagnostics.shared.record("user_reported_slow"); PerformanceDiagnostics.shared.flush() }
        }
    }
}

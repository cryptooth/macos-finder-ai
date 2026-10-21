// Finder AI — a tiny AI panel launched from the Finder toolbar (Claude or ChatGPT)
// Build: ./build.sh

import AppKit
import SwiftUI

// MARK: - Settings

let maxListedItems = 800        // max number of folder items sent to the AI

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "ChatGPT" }
    var binary: String { self == .claude ? "claude" : "codex" }
    /// Quick picks shown in the menu next to the model field
    var presets: [String] { self == .claude ? ["sonnet", "haiku", "opus"] : [] }
    var defaultModel: String { self == .claude ? "sonnet" : "" }
    var installHint: String {
        self == .claude
            ? "Is Claude Code installed? (In Terminal: which claude)"
            : "Is Codex CLI installed? Install with: npm i -g @openai/codex, then run: codex login"
    }
}

// MARK: - Errors

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Finder context

struct FinderContext {
    let folder: URL
    let selection: [URL]
}

func readFinderContext() -> FinderContext {
    let source = """
    tell application "Finder"
        set out to ""
        try
            set out to POSIX path of (target of front window as alias)
        on error
            set out to POSIX path of (path to desktop folder)
        end try
        try
            repeat with f in (selection as alias list)
                set out to out & linefeed & (POSIX path of f)
            end repeat
        end try
        return out
    end tell
    """
    var err: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue ?? ""
    var lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
    let folder: URL
    if lines.isEmpty {
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    } else {
        folder = URL(fileURLWithPath: lines.removeFirst(), isDirectory: true)
    }
    return FinderContext(folder: folder, selection: lines.map { URL(fileURLWithPath: $0) })
}

// MARK: - Path helpers

func folderPrefix(_ base: URL) -> String {
    let b = base.standardizedFileURL.path
    return b.hasSuffix("/") ? b : b + "/"
}

func relativePath(_ url: URL, to base: URL) -> String {
    let p = url.standardizedFileURL.path
    let prefix = folderPrefix(base)
    return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
}

/// Safely resolves a relative path from the AI; rejects anything that escapes the folder.
func resolve(_ rel: String?, in base: URL) throws -> URL {
    guard let rel, !rel.isEmpty, !rel.hasPrefix("/"), !rel.hasPrefix("~") else {
        throw AppError("Invalid path: \(rel ?? "(empty)")")
    }
    let url = base.appendingPathComponent(rel).standardizedFileURL
    guard url.path.hasPrefix(folderPrefix(base)) else {
        throw AppError("Rejected a path outside the folder: \(rel)")
    }
    return url
}

func listing(of folder: URL) -> [String] {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    return items.map { u in
        let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return u.lastPathComponent + (isDir ? "/" : "")
    }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

// MARK: - Plan

struct Op: Decodable, Identifiable {
    var id = UUID()
    let op: String
    let path: String?
    let from: String?
    let to: String?
    enum CodingKeys: String, CodingKey { case op, path, from, to }
}

struct Plan: Decodable {
    let summary: String?
    let ops: [Op]
}

func buildPrompt(request: String, ctx: FinderContext) -> String {
    let all = listing(of: ctx.folder)
    let truncNote = all.count > maxListedItems ? " (first \(maxListedItems) items)" : ""
    var s = "You are an assistant that organizes files on macOS. Working folder: \(ctx.folder.path)\n\n"
    if !ctx.selection.isEmpty {
        s += "The user selected these items in Finder (work only with these unless the request says otherwise):\n"
        s += ctx.selection.map { "- " + relativePath($0, to: ctx.folder) }.joined(separator: "\n")
        s += "\n\n"
    }
    s += "Folder contents\(truncNote); entries ending in / are folders:\n"
    s += all.prefix(maxListedItems).map { "- " + $0 }.joined(separator: "\n")
    s += """


    User request: \(request)

    Do not modify any files yourself and do not run commands. Return exactly ONE JSON object and no other text before or after it:
    {"summary":"short English summary","ops":[{"op":"mkdir","path":"New Folder"},{"op":"move","from":"old.pdf","to":"New Folder/new.pdf"}]}
    Rules:
    - All paths are relative to the working folder; never use ".." or absolute paths.
    - Renames are also expressed as "move"; keep file extensions unless asked otherwise.
    - There is no delete operation; if deletion is requested, leave ops empty and explain in summary.
    - A mkdir must come before any move into that folder. Never overwrite an existing file.
    - If there is nothing to do, leave ops empty and explain why in summary.
    """
    return s
}

func parsePlan(_ text: String) throws -> Plan {
    guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e else {
        throw AppError("No valid plan was returned:\n\(text.prefix(400))")
    }
    do {
        return try JSONDecoder().decode(Plan.self, from: Data(text[s...e].utf8))
    } catch {
        throw AppError("Could not parse the plan: \(error.localizedDescription)")
    }
}

// MARK: - CLI calls (claude / codex)

func findBinary(_ name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "\(home)/.local/bin/\(name)",
        "\(home)/.claude/local/\(name)",
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
    ]
    if let c = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return c }

    // Not found: ask the user's login shell (covers nvm and custom npm prefixes)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lic", "command -v \(name)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    return out.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") })
}

/// Runs a process, reading stdout and stderr concurrently so a full pipe buffer can't deadlock it.
func runProcess(_ bin: String, _ args: [String], cwd: URL) async throws -> (status: Int32, out: String, err: String) {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            let dir = (bin as NSString).deletingLastPathComponent
            env["PATH"] = "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(throwing: error); return }

            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            p.waitUntilExit()
            cont.resume(returning: (p.terminationStatus,
                                    String(decoding: outData, as: UTF8.self),
                                    String(decoding: errData, as: UTF8.self)))
        }
    }
}

func runAgent(_ provider: Provider, model: String, prompt: String, cwd: URL) async throws -> String {
    guard let bin = findBinary(provider.binary) else {
        throw AppError("Command '\(provider.binary)' not found. \(provider.installHint)")
    }
    let m = model.trimmingCharacters(in: .whitespacesAndNewlines)

    switch provider {
    case .claude:
        var args = ["-p", prompt, "--output-format", "json"]
        if !m.isEmpty { args += ["--model", m] }
        let r = try await runProcess(bin, args, cwd: cwd)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              let result = obj["result"] as? String else {
            throw AppError("Could not read Claude's response:\n\((r.err + r.out).prefix(600))")
        }
        if (obj["is_error"] as? Bool) == true { throw AppError(result) }
        return result

    case .codex:
        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outFile) }
        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only",
                    "--output-last-message", outFile.path]
        if !m.isEmpty { args += ["--model", m] }
        args.append(prompt)
        let r = try await runProcess(bin, args, cwd: cwd)
        let last = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let text = last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? r.out : last
        if r.status != 0 && !text.contains("{") {
            throw AppError("ChatGPT (codex) returned an error:\n\(String((r.err + r.out).suffix(600)))")
        }
        return text
    }
}

// MARK: - Apply / undo

enum UndoStep {
    case move(from: URL, to: URL)
    case rmdir(URL)
}

/// Also handles case-only renames (a.pdf → A.pdf) on case-insensitive volumes.
func safeMove(_ src: URL, _ dst: URL) throws {
    let fm = FileManager.default
    if src.path != dst.path && src.path.lowercased() == dst.path.lowercased() {
        let tmp = src.deletingLastPathComponent().appendingPathComponent(".finderai-\(UUID().uuidString)")
        try fm.moveItem(at: src, to: tmp)
        try fm.moveItem(at: tmp, to: dst)
    } else {
        try fm.moveItem(at: src, to: dst)
    }
}

func validate(_ plan: Plan, in base: URL) throws {
    for op in plan.ops {
        switch op.op {
        case "mkdir": _ = try resolve(op.path, in: base)
        case "move": _ = try resolve(op.from, in: base); _ = try resolve(op.to, in: base)
        default: throw AppError("Unknown operation: \(op.op)")
        }
    }
}

func execute(_ plan: Plan, in base: URL, undo: inout [UndoStep]) throws {
    let fm = FileManager.default
    for op in plan.ops {
        switch op.op {
        case "mkdir":
            let url = try resolve(op.path, in: base)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue { continue }
                throw AppError("Can't create folder, a file with that name exists: \(op.path ?? "")")
            }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            undo.append(.rmdir(url))

        case "move":
            let src = try resolve(op.from, in: base)
            let dst = try resolve(op.to, in: base)
            guard fm.fileExists(atPath: src.path) else {
                throw AppError("Source not found: \(op.from ?? "")")
            }
            let caseOnly = src.path != dst.path && src.path.lowercased() == dst.path.lowercased()
            if !caseOnly && fm.fileExists(atPath: dst.path) {
                throw AppError("Destination already exists: \(op.to ?? "")")
            }
            let parent = dst.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                undo.append(.rmdir(parent))
            }
            try safeMove(src, dst)
            undo.append(.move(from: dst, to: src))

        default:
            throw AppError("Unknown operation: \(op.op)")
        }
    }
}

func revert(_ steps: [UndoStep]) -> [String] {
    var errors: [String] = []
    let fm = FileManager.default
    for step in steps.reversed() {
        do {
            switch step {
            case .move(let from, let to):
                try safeMove(from, to)
            case .rmdir(let url):
                // Only remove if empty (ignoring .DS_Store)
                let rest = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
                if rest.isEmpty { try fm.removeItem(at: url) }
            }
        } catch {
            errors.append(error.localizedDescription)
        }
    }
    return errors
}

// MARK: - Model

enum Phase {
    case input
    case thinking
    case preview(Plan)
    case done(String)
    case failed(String)
}

@MainActor
final class Model: ObservableObject {
    @Published var ctx = readFinderContext()
    @Published var request = ""
    @Published var phase: Phase = .input
    @Published var activeName = ""
    @Published private(set) var undo: [UndoStep] = []
    private var task: Task<Void, Never>?

    var canUndo: Bool { !undo.isEmpty }

    func refresh() {
        task?.cancel()
        ctx = readFinderContext()
        phase = .input
        undo = []
    }

    func submit(provider: Provider, model: String) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        activeName = provider.title + (m.isEmpty ? "" : " (\(m))")
        phase = .thinking
        let ctx = self.ctx
        task = Task {
            do {
                let raw = try await runAgent(provider, model: m, prompt: buildPrompt(request: text, ctx: ctx), cwd: ctx.folder)
                let plan = try parsePlan(raw)
                try validate(plan, in: ctx.folder)
                if !Task.isCancelled { phase = .preview(plan) }
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func apply(_ plan: Plan) {
        var steps: [UndoStep] = []
        do {
            try execute(plan, in: ctx.folder, undo: &steps)
            undo = steps
            phase = .done(plan.ops.count == 1 ? "1 operation completed." : "\(plan.ops.count) operations completed.")
        } catch {
            undo = steps
            var msg = "Stopped: \(error.localizedDescription)"
            if !steps.isEmpty { msg += "\nYou can undo the \(steps.count) step(s) completed so far." }
            phase = .failed(msg)
        }
    }

    func undoAll() {
        let errs = revert(undo)
        undo = []
        phase = errs.isEmpty ? .done("Undone.") : .failed("Undo errors:\n" + errs.joined(separator: "\n"))
    }

    func newRequest() {
        request = ""
        undo = []
        phase = .input
    }
}

// MARK: - UI

struct OpRow: View {
    let op: Op
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if op.op == "mkdir" {
                Image(systemName: "folder.badge.plus").foregroundStyle(.blue)
                Text(op.path ?? "")
            } else {
                Image(systemName: "arrow.right").foregroundStyle(.orange)
                Text(op.from ?? "").foregroundStyle(.secondary)
                Text("→").foregroundStyle(.secondary)
                Text(op.to ?? "")
            }
        }
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

struct PanelView: View {
    @ObservedObject var m: Model
    var close: () -> Void
    @FocusState private var focused: Bool

    // Choices are remembered (UserDefaults)
    @AppStorage("provider") private var providerRaw = Provider.claude.rawValue
    @AppStorage("model.claude") private var claudeModel = Provider.claude.defaultModel
    @AppStorage("model.codex") private var codexModel = Provider.codex.defaultModel

    private var provider: Provider { Provider(rawValue: providerRaw) ?? .claude }

    private var modelBinding: Binding<String> {
        provider == .claude ? $claudeModel : $codexModel
    }

    private func submit() { m.submit(provider: provider, model: modelBinding.wrappedValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch m.phase {
            case .input:
                providerRow
                TextField("What should I do? e.g. move all PDFs into an Invoices folder", text: $m.request, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { submit() }
                    .onAppear { focused = true }
                HStack {
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button("Plan") { submit() }.keyboardShortcut(.defaultAction)
                }

            case .thinking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(m.activeName) is preparing a plan…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                }

            case .preview(let plan):
                if let s = plan.summary, !s.isEmpty {
                    Text(s).font(.callout)
                }
                if !plan.ops.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.ops) { OpRow(op: $0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: min(CGFloat(plan.ops.count) * 22 + 16, 280))
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button("Edit") { m.phase = .input }
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button("Apply (\(plan.ops.count))") { m.apply(plan) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(plan.ops.isEmpty)
                }

            case .done(let msg):
                Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    if m.canUndo { Button("Undo") { m.undoAll() } }
                    Spacer()
                    Button("New Request") { m.newRequest() }
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }

            case .failed(let msg):
                Text(msg).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                HStack {
                    if m.canUndo { Button("Undo") { m.undoAll() } }
                    Spacer()
                    Button("Try Again") { m.phase = .input }
                    Button("Close", action: close).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(16)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(m.ctx.folder.lastPathComponent).font(.headline).lineLimit(1)
            if !m.ctx.selection.isEmpty {
                Text("· \(m.ctx.selection.count) selected").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .help(m.ctx.folder.path)
    }

    private var providerRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $providerRaw) {
                ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            TextField("model: default", text: modelBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            if !provider.presets.isEmpty {
                Menu {
                    ForEach(provider.presets, id: \.self) { p in
                        Button(p) { modelBinding.wrappedValue = p }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
        }
        .font(.callout)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var model: Model!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        p.title = "Finder AI"
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.delegate = self
        p.contentView = NSHostingView(rootView: PanelView(m: model, close: { NSApp.terminate(nil) }))
        panel = p
        show()
    }

    func show() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // If the toolbar icon is clicked again while open: refresh the Finder context
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.refresh()
        show()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

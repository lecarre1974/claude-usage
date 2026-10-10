import SwiftUI

struct SettingsPanel: View {
    @Binding var isPresented: Bool
    @AppStorage(Prefs.menuBarStyle) private var style = MenuBarStyle.iconOnly.rawValue
    @AppStorage(Prefs.dailyBudget) private var dailyBudget = 0.0
    @AppStorage(Prefs.blockBudget) private var blockBudget = 0.0
    @AppStorage(Prefs.refreshSeconds) private var refresh = 5.0
    @AppStorage(Prefs.notifyFinished) private var notifyFinished = true
    @AppStorage(Prefs.notifyBudget) private var notifyBudget = true
    @AppStorage(Prefs.animateIcon) private var animate = true
    @AppStorage(Prefs.planLimits) private var planLimits = false
    @AppStorage(Prefs.notifyShowText) private var notifyShowText = true
    @State private var confirmClear = false
    @AppStorage(ClaudeConfig.extraDirsKey) private var extraDirs = ""
    @AppStorage(Prefs.notifyRunaway) private var notifyRunaway = true
    @AppStorage(Prefs.runawayDollars) private var runawayDollars = 25.0
    @AppStorage(Prefs.notifyGame) private var notifyGame = true
    @AppStorage(Prefs.hotkey) private var hotkey = true
    @Environment(UsageStore.self) private var store
    @State private var launchAtLogin = UsageStore.launchAtLogin

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction).controlSize(.small)
            }
            .padding(12)
            Divider()
            Form {
                Section("Menu bar") {
                    Picker("Show", selection: $style) {
                        ForEach(MenuBarStyle.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Toggle("Animate icon while Claude is working", isOn: $animate)
                }
                Section("Plan limits") {
                    Toggle("Show real plan limits from Anthropic", isOn: $planLimits)
                        .onChange(of: planLimits) { _, _ in
                            UserDefaults.standard.set(true, forKey: Prefs.planLimitsAsked)   // don't re-show the first-run card
                            Task { await store.refreshPlan() }
                        }
                    if planLimits {
                        Group {
                            if store.plan.isConnected {
                                Label("Connected\(store.plan.plan.map { " · \($0) plan" } ?? "") · updated \(store.plan.fetchedAt.map { Fmt.ago($0) } ?? "–")", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Palette.good)
                            } else if let e = store.plan.error {
                                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.serious)
                            } else {
                                Label("Connecting…", systemImage: "hourglass")
                            }
                        }
                        .font(.system(size: 10.5))
                    }
                    Text("Reads Claude Code's login from your Keychain (via /usr/bin/security) and asks api.anthropic.com for your usage — the same numbers as /usage. Never refreshes or changes your login. This endpoint is undocumented and may change; if it does, the app falls back to an estimate.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section("Budgets (API-equivalent $)") {
                    LabeledContent("Daily budget") {
                        TextField("", value: $dailyBudget, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 80).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("5-hour block gauge") {
                        TextField("", value: $blockBudget, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 80).multilineTextAlignment(.trailing)
                    }
                    Text("0 = off for the daily budget; 0 = use your busiest block as the gauge's 100%.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section("Notifications") {
                    Toggle("When a session finishes and is waiting for you", isOn: $notifyFinished)
                    Toggle("When the daily budget is reached", isOn: $notifyBudget)
                    Toggle("Achievements, level-ups and quests", isOn: $notifyGame)
                    Toggle("Runaway sessions (fast burn or 45+ min non-stop)", isOn: $notifyRunaway)
                    Toggle("Include session titles in notifications", isOn: $notifyShowText)
                    if notifyRunaway {
                        LabeledContent("Fast burn = 10-min spend over") {
                            TextField("", value: $runawayDollars, format: .currency(code: "USD").precision(.fractionLength(0)))
                                .frame(width: 70).multilineTextAlignment(.trailing)
                        }
                    }
                    if !Bundle.main.bundlePath.hasSuffix(".app") && !UsageStore.isSandboxed {
                        Text("Notifications need the bundled app (run ./install.sh).").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Section("General") {
                    Picker("Refresh every", selection: $refresh) {
                        Text("2 s").tag(2.0); Text("5 s").tag(5.0); Text("15 s").tag(15.0); Text("60 s").tag(60.0)
                    }
                    Toggle("Global shortcut ⌥⌘C opens the popover", isOn: $hotkey)
                    LabeledContent("Extra Claude folders") {
                        TextField("", text: $extraDirs, prompt: Text("~/work/.claude"))
                            .frame(width: 200)
                            .onSubmit { Task { await store.refresh() } }
                    }
                    Text("Only needed if you set CLAUDE_CONFIG_DIR. Comma-separated. ~/.claude and ~/.config/claude are always read.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, v in UsageStore.launchAtLogin = v }
                    HStack {
                        Button("Open Claude folder") {
                            let dir = ClaudeConfig.dirs.first ?? FileManager.default.homeDirectoryForCurrentUser
                            NSWorkspace.shared.open(dir)
                        }
                        Spacer()
                        Button("Quit Claude Usage") { NSApp.terminate(nil) }
                    }
                }
                Section("History") {
                    Text("Claude Code deletes transcripts older than `cleanupPeriodDays` (default 30) from ~/.claude/settings.json. Claude Usage keeps its own archive in ~/Library/Application Support/ClaudeUsage so your history survives — raising cleanupPeriodDays also keeps full transcripts around.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("The archive stores usage numbers, session titles, launch folders, git branches, PR links, models, tool names and prompt previews (280 chars). It never stores credentials.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Button("Show archive in Finder") {
                            if FileManager.default.fileExists(atPath: Archive.url.path) {
                                NSWorkspace.shared.activateFileViewerSelecting([Archive.url])
                            } else {
                                NSWorkspace.shared.open(Archive.url.deletingLastPathComponent())
                            }
                        }
                        Spacer()
                        Button("Clear archive…", role: .destructive) { confirmClear = true }
                            .disabled(UsageStore.isSandboxed)
                    }
                    .confirmationDialog("Clear the archive?", isPresented: $confirmClear) {
                        Button("Clear archive", role: .destructive) { Task { await store.clearArchive() } }
                    } message: {
                        Text("History for transcripts Claude Code has already deleted will be gone for good. Current transcripts are re-read.")
                    }
                }
                Section {
                    Text("Reads ~/.claude/projects transcripts and ~/.claude/sessions locally. Nothing leaves your Mac except the optional plan-limits request to api.anthropic.com. Costs use Anthropic API list prices; on a Pro/Max plan they reflect value, not your bill. Not affiliated with Anthropic.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial)
        .onChange(of: notifyFinished) { _, v in if v { UsageStore.requestNotificationPermission() } }
    }
}

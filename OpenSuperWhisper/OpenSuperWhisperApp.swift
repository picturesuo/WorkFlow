//
//  OpenSuperWhisperApp.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@main
struct OpenSuperWhisperApp: App {
    nonisolated static let isRunningTests = NSClassFromString("XCTestCase") != nil

    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.isRunningTests {
                    EmptyView()
                } else if !appState.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                }
            }
            .frame(minWidth: 440, idealWidth: 560, minHeight: 460)
            .environmentObject(appState)
            .tint(ThemePalette.controlTint)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 560, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.showMainWindow()
                    }
                    SettingsRequest.open()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))
    }

    init() {
        // First, also under tests: registered after ggml's load-time statics,
        // so at exit it runs before their destructors.
        ProcessExitGate.installAtExit()
        guard !Self.isRunningTests else { return }
        do {
            try RenamedAppMigration.migrateApplicationSupport()
        } catch {
            print("Unable to migrate application data to \(AppIdentity.productName).")
        }
        _ = ShortcutManager.shared
        _ = MicrophoneService.shared
        WhisperModelManager.shared.ensureDefaultModelPresent()
    }
}

extension OpenSuperWhisperApp {
    static func startTranscriptionQueue() {
        Task { @MainActor in
            TranscriptionQueue.shared.startProcessingQueue()
            // Only dictations whose measurement was cut off by quitting.
            let store = RecordingStore.shared
            Task.detached(priority: .utility) {
                await store.measureInterruptedSpeechActivity()
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    init() {
        var onboarding = AppPreferences.shared.hasCompletedOnboarding
        #if DEBUG
        if let force = DevConfig.shared.forceShowOnboarding {
            onboarding = !force
        }
        #endif
        self.hasCompletedOnboarding = onboarding
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var languageSubmenu: NSMenu?
    private var microphoneService = MicrophoneService.shared
    private var microphoneObserver: AnyCancellable?
    private var meetingObserver: AnyCancellable?
    private var meetingErrorObserver: AnyCancellable?
    private var recordingRetentionTimer: Timer?
    private var hideMainWindowAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The XCTest host renders views offscreen. Keeping it out of the Dock
        // stops a test run from taking focus away from the user's work.
        if OpenSuperWhisperApp.isRunningTests {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !OpenSuperWhisperApp.isRunningTests else { return }

        setupStatusBarItem()
        migrateLegacyCredentialsInBackground()

        // The WindowGroup window usually does not exist yet at this point:
        // SwiftUI creates it after applicationDidFinishLaunching, so it is
        // adopted lazily from windowDidBecomeKey instead.
        if let window = Self.resolveMainWindow() {
            adoptMainWindow(window)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        // SwiftUI owns the WindowGroup window and can replace its delegate,
        // so windowWillClose on AppDelegate is not guaranteed to fire. The
        // notification is delivered regardless of who the delegate is.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cleanupModePreferenceChanged),
            name: .cleanupModeChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languagePreferenceChanged),
            name: .appPreferencesLanguageChanged,
            object: nil
        )

        let prefs = AppPreferences.shared
        LaunchAtLoginManager.reconcile(enabled: prefs.launchAtLogin)
        if prefs.startHiddenInMenuBar && prefs.hasCompletedOnboarding {
            hideMainWindowAtLaunch = true
            mainWindow?.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        OpenSuperWhisperApp.startTranscriptionQueue()
        // Stale temporary recordings go only once History says which ones it
        // still uses (queued, or kept after a failed move); if it cannot say, none go.
        Task { @MainActor in
            guard let referenced = try? await RecordingStore.shared.referencedAudioPaths() else { return }
            AudioRecorder.shared.sweepTemporaryRecordings(keeping: referenced)
        }
        observeMicrophoneChanges()
        observeMeetingChanges()
        
        IndicatorWindowManager.shared.warmUp()
        
        startRecordingRetentionSchedule()

        Task { @MainActor in
            await RecordingStore.shared.backfillMissingDurations()
        }
        PerfSignpost.eventSinceProcessStart("launch_ready")
    }

    private func migrateLegacyCredentialsInBackground() {
        Task.detached(priority: .utility) {
            do {
                _ = try BedrockCredentialStore.loadAPIKey()
            } catch {
                print("WorkFlow could not migrate a legacy Bedrock credential.")
            }

            do {
                _ = try CleanupCredentialStore.loadAPIKey()
            } catch {
                print("WorkFlow could not migrate a legacy cleanup credential.")
            }
        }
    }

    private func startRecordingRetentionSchedule() {
        cleanupOutdatedRecordings()
        
        // Scheduled on the main run loop, so it fires on the main actor.
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanupOutdatedRecordings() }
        }
        timer.tolerance = 60 * 60
        recordingRetentionTimer = timer
    }

    private func cleanupOutdatedRecordings() {
        let prefs = AppPreferences.shared
        guard prefs.autoDeleteRecordingsEnabled else { return }
        let days = prefs.autoDeleteRecordingsAfterDays
        Task { @MainActor in
            try? await RecordingStore.shared.deleteRecordings(olderThanDays: days)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard isAudioFile(url) else {
            return false
        }

        queueAudioURLs([url])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let audioURLs = filenames
            .map { URL(fileURLWithPath: $0) }
            .filter { isAudioFile($0) }

        sender.reply(toOpenOrPrint: audioURLs.isEmpty ? .failure : .success)
        queueAudioURLs(audioURLs)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let audioURLs = urls.filter { isAudioFile($0) }
        queueAudioURLs(audioURLs)
    }

    private func queueAudioURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            showMainWindow()

            for url in urls {
                await TranscriptionQueue.shared.addFileToQueue(url: url)
            }
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType.conforms(to: .audio)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
    
    private func observeMicrophoneChanges() {
        microphoneObserver = microphoneService.$availableMicrophones
            .sink { [weak self] _ in
                self?.updateStatusBarMenu()
            }
    }

    private func observeMeetingChanges() {
        meetingObserver = MeetingSessionController.shared.$state
            .sink { [weak self] _ in
                self?.updateStatusBarMenu()
            }
        meetingErrorObserver = MeetingSessionController.shared.$errorMessage
            .sink { [weak self] _ in
                self?.updateStatusBarMenu()
            }
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            if let iconImage = NSImage(named: "tray_icon") {
                iconImage.size = NSSize(width: 48, height: 48)
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: AppIdentity.productName)
            }
            
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }
        
        updateStatusBarMenu()
    }
    
    private func updateStatusBarMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        menu.addItem(NSMenuItem(title: AppIdentity.productName, action: #selector(openApp), keyEquivalent: "o"))

        // Meetings are occasional: Start sits low in the menu, but a meeting
        // that is recording, saving, or failed comes first so it can be stopped
        // or explained.
        let meeting = MeetingSessionController.shared
        let meetingItem = NSMenuItem(
            title: Self.meetingMenuTitle(meeting),
            action: #selector(toggleMeeting),
            keyEquivalent: ""
        )
        meetingItem.target = self
        meetingItem.isEnabled = !meeting.isSaving
        let meetingNeedsAttention = meeting.isBusy || meeting.errorMessage != nil
        if meetingNeedsAttention {
            menu.addItem(meetingItem)
        }

        let cleanupModeItem = NSMenuItem(title: "Dictation Mode", action: nil, keyEquivalent: "")
        let cleanupModeMenu = NSMenu()
        DictationModeMenu.populate(
            cleanupModeMenu,
            filters: CustomCleanupFilterStore.load(),
            isAuto: FilterAutoSettings.isEnabled(),
            selection: CustomCleanupFilterStore.currentSelection(),
            fallback: FilterAutoSettings.fallback(),
            target: self,
            select: #selector(selectCleanupMode(_:)),
            selectAuto: #selector(selectAutoFilter),
            manage: #selector(openFilters)
        )
        cleanupModeMenu.addItem(.separator())
        let learnItem = NSMenuItem(
            title: "Learn from Finished Writing…",
            action: #selector(openLearning),
            keyEquivalent: ""
        )
        learnItem.target = self
        learnItem.toolTip = "Teach a dictation mode your style from a document you finished"
        cleanupModeMenu.addItem(learnItem)
        cleanupModeItem.submenu = cleanupModeMenu
        menu.addItem(cleanupModeItem)
        
        let transcriptionLanguageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageSubmenu = NSMenu()
        
        if let languageSubmenu {
            populateLanguageSubmenu(languageSubmenu)
        }
        
        transcriptionLanguageItem.submenu = languageSubmenu
        menu.addItem(transcriptionLanguageItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let microphoneMenu = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        
        let microphones = microphoneService.availableMicrophones
        let currentMic = microphoneService.currentMicrophone
        
        if microphones.isEmpty {
            let noDeviceItem = NSMenuItem(title: "No microphones available", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            submenu.addItem(noDeviceItem)
        } else {
            let builtInMicrophones = microphones.filter { $0.isBuiltIn }
            let externalMicrophones = microphones.filter { !$0.isBuiltIn }
            
            for microphone in builtInMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
            
            if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }
            
            for microphone in externalMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
        }
        
        microphoneMenu.submenu = submenu
        menu.addItem(microphoneMenu)

        if !meetingNeedsAttention {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(meetingItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? MicrophoneService.AudioDevice else { return }
        microphoneService.selectMicrophone(device)
        updateStatusBarMenu()
    }
    
    @objc private func statusBarButtonClicked(_ sender: Any) {
        statusItem?.button?.performClick(nil)
    }
    
    @objc private func openApp() {
        showMainWindow()
    }

    @objc private func openFilters() {
        showMainWindow()
        SettingsRequest.open(pane: .cleanup)
    }

    @objc private func openLearning() {
        showMainWindow()
        SettingsRequest.open(pane: .personalize)
    }

    /// Idle reads as an action, the way the main window's More menu does.
    static func meetingMenuTitle(_ meeting: MeetingSessionController) -> String {
        meeting.state == .idle && meeting.errorMessage == nil ? "Start Meeting Recording" : meeting.statusLabel
    }

    @objc private func toggleMeeting() {
        let meeting = MeetingSessionController.shared
        if meeting.isRecording {
            Task { await meeting.stop() }
        } else if !meeting.isBusy {
            _ = meeting.start(title: MeetingSessionController.defaultTitle())
        }
    }

    @objc private func selectAutoFilter() {
        FilterAutoSettings.setEnabled(true)
        NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
    }

    @objc private func selectCleanupMode(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String,
              let selection = CleanupFilterSelection(tag: tag) else { return }
        CustomCleanupFilterStore.select(selection)
        NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
    }

    @objc private func cleanupModePreferenceChanged() {
        updateStatusBarMenu()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let languageCode = sender.representedObject as? String else { return }
        
        // Update preferences
        AppPreferences.shared.whisperLanguage = languageCode
        
        // Update menu item states
        if let submenu = sender.menu {
            for item in submenu.items {
                item.state = .off
            }
            sender.state = .on
        }
    }
    
    @objc private func languagePreferenceChanged() {
        updateLanguageMenuSelection()
    }
    
    private func updateLanguageMenuSelection() {
        guard let languageSubmenu = languageSubmenu else { return }
        populateLanguageSubmenu(languageSubmenu)
    }
    
    private func populateLanguageSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        
        let supportedLanguages = LanguageUtil.supportedLanguages(
            engine: AppPreferences.shared.selectedEngine,
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
        let currentLanguage = AppPreferences.shared.whisperLanguage
        
        for languageCode in supportedLanguages {
            let languageName = LanguageUtil.languageNames[languageCode] ?? languageCode
            let languageItem = NSMenuItem(title: languageName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = languageCode
            languageItem.state = (currentLanguage == languageCode) ? .on : .off
            submenu.addItem(languageItem)
        }
    }
    
    /// The WindowGroup window must be told apart from the other windows the
    /// app creates: the status item's NSStatusBarWindow, the borderless
    /// indicator NSPanel and SwiftUI sheet host windows.
    static func isMainAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && !window.isSheet && window.styleMask.contains(.titled)
    }

    private static func resolveMainWindow() -> NSWindow? {
        NSApplication.shared.windows.first(where: isMainAppWindow)
    }

    /// SwiftUI creates the WindowGroup window after applicationDidFinishLaunching
    /// and can recreate it later, so the reference is (re)captured whenever a
    /// main-type window becomes key.
    @objc private func anyWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              Self.isMainAppWindow(window),
              window !== mainWindow
        else { return }
        adoptMainWindow(window)
    }

    private func adoptMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
        window.minSize = NSSize(width: 440, height: 460)

        if hideMainWindowAtLaunch {
            hideMainWindowAtLaunch = false
            window.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    @objc private func anyWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, Self.isMainAppWindow(closing) else { return }
        // Deferred so the check runs after the window has actually closed.
        DispatchQueue.main.async {
            let anyMainWindowVisible = NSApplication.shared.windows.contains {
                $0 !== closing && Self.isMainAppWindow($0) && $0.isVisible
            }
            if !anyMainWindowVisible {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }

    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)

        if mainWindow == nil {
            mainWindow = Self.resolveMainWindow()
        }

        if mainWindow?.isVisible != true {
            PerfSignpost.begin(.historyOpen)
        }
        if let window = mainWindow {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            let url = URL(string: "openSuperWhisper://openMainWindow")!
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSWindowDelegate {}

/// The menu-bar Dictation Mode menu: Auto, the built-in modes, and saved
/// filters, which stay flat while few and move into submenus by base mode
/// once the collection is large.
enum DictationModeMenu {
    static func populate(
        _ menu: NSMenu,
        filters: [CustomCleanupFilter],
        isAuto: Bool,
        selection: CleanupFilterSelection,
        fallback: CleanupFilterSelection,
        fallbackName: String? = nil,
        target: AnyObject,
        select: Selector,
        selectAuto: Selector,
        manage: Selector
    ) {
        func writingItem(_ title: String, selection item: CleanupFilterSelection, toolTip: String) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: select, keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = item.tag
            menuItem.state = !isAuto && item == selection ? .on : .off
            menuItem.toolTip = toolTip
            return menuItem
        }
        let fallbackName: String = fallbackName ?? {
            switch fallback {
            case .builtIn(let mode): mode.displayName
            case .custom(let id): filters.first { $0.id == id }?.name ?? CleanupMode.everyday.displayName
            }
        }()
        let autoItem = NSMenuItem(title: WritingFilterPicker.autoTitle, action: selectAuto, keyEquivalent: "")
        autoItem.target = target
        autoItem.state = isAuto ? .on : .off
        autoItem.toolTip = "Picks a saved filter when two of its phrases come up; otherwise \(fallbackName)."
        menu.addItem(autoItem)
        menu.addItem(.separator())
        for mode in CleanupMode.allCases {
            menu.addItem(writingItem(mode.displayName, selection: .builtIn(mode), toolTip: mode.description))
        }
        if !filters.isEmpty {
            menu.addItem(.separator())
            if FilterCollection.isLarge(filters) {
                for group in FilterCollection.grouped(filters) {
                    let groupItem = NSMenuItem(
                        title: "Based on \(group.mode.displayName) (\(group.filters.count))", action: nil, keyEquivalent: ""
                    )
                    let groupMenu = NSMenu()
                    groupMenu.autoenablesItems = false
                    for filter in group.filters {
                        groupMenu.addItem(writingItem(filter.name, selection: .custom(filter.id), toolTip: filter.summary))
                    }
                    groupItem.submenu = groupMenu
                    // The group holding the filter in use shows a dash.
                    groupItem.state = !isAuto && group.filters.contains { .custom($0.id) == selection } ? .mixed : .off
                    menu.addItem(groupItem)
                }
            } else {
                for filter in filters {
                    menu.addItem(writingItem(filter.name, selection: .custom(filter.id), toolTip: filter.summary))
                }
            }
        }
        menu.addItem(.separator())
        let manageItem = NSMenuItem(title: "Manage Filters…", action: manage, keyEquivalent: "")
        manageItem.target = target
        manageItem.toolTip = "Create, edit, and search custom filters, and set up Auto"
        menu.addItem(manageItem)
    }
}

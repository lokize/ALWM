import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - AX tracker — observe/scan/publish

extension AXTracker {

    func observe(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<AXTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handle(notification: notification as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        let app = AXUIElementCreateApplication(pid)
        let notes = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification
        ]
        for note in notes {
            AXObserverAddNotification(observer, app, note as CFString, ref)
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        observers[pid] = observer
        runLoopSources[pid] = source
    }


    func observeTitle(on window: AXUIElement, pid: pid_t, token: String) {
        guard !titleObservedTokens.contains(token), let observer = observers[pid] else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        let status = AXObserverAddNotification(
            observer,
            window,
            kAXTitleChangedNotification as CFString,
            ref
        )
        if status == .success || status == .notificationAlreadyRegistered {
            titleObservedTokens.insert(token)
        }
    }


    func handle(notification: String, element: AXUIElement) {
        // Self-caused layout noise — ignore until settle (except destroy: red-X must not wait).
        if isMutating {
            if notification == kAXFocusedWindowChangedNotification as String,
               let id = windowID(for: element) {
                delegate?.axTrackerFocusedWindowDidChange(id)
            }
            if notification == kAXUIElementDestroyedNotification as String,
               let id = windowID(for: element) {
                delegate?.axTrackerWindowDidClose(id)
                scheduleScanAll(delay: 0.12)
            }
            return
        }

        if notification == kAXFocusedWindowChangedNotification as String {
            if let id = windowID(for: element) {
                refreshTitle(for: id)
                delegate?.axTrackerFocusedWindowDidChange(id)
            }
            // Focus alone should not full-rescan.
            return
        }

        if notification == kAXTitleChangedNotification as String {
            if let id = windowID(for: element) {
                refreshTitle(for: id)
            }
            return
        }

        // User/app moved or resized a window — let the WM re-assert tiled layout if needed.
        if notification == kAXMovedNotification as String
            || notification == kAXResizedNotification as String {
            if !isMutating, let id = windowID(for: element) {
                delegate?.axTrackerWindowGeometryChanged(id)
            }
            return
        }

        if notification == kAXUIElementDestroyedNotification as String {
            if let id = windowID(for: element) {
                // Drop local cache immediately so the next scan does not resurrect a ghost.
                axWindows.removeValue(forKey: id)
                managed.removeValue(forKey: id)
                delegate?.axTrackerWindowDidClose(id)
            }
            scheduleScanAll(delay: 0.12)
            return
        }

        // Create/deminiaturize — full rescan.
        let structural = notification == kAXWindowCreatedNotification as String
            || notification == kAXWindowDeminiaturizedNotification as String
        guard structural else { return }

        scheduleScanAll(delay: 0.28)
    }


    func scheduleScanAll(delay: TimeInterval) {
        scanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isMutating else { return }
            self.scanAll()
        }
        scanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }


    func windowID(for element: AXUIElement) -> WindowID? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let n = readWindowNumber(element) {
            return WindowID(pid: pid, windowNumber: n)
        }
        return axWindows.first(where: { CFEqual($0.value.element, element) })?.key
    }


    func readWindowNumber(_ element: AXUIElement) -> Int? {
        var numObj: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXWindowNumberAttribute as CFString, &numObj) == .success,
           let n = AXBridge.int(numObj) {
            return n
        }
        return nil
    }


    /// On-screen CG window numbers by PID (fallback when AXWindowNumber is missing).
    func cgWindowNumbersByPID() -> [pid_t: [Int]] {
        var result: [pid_t: [Int]] = [:]
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return result }

        for info in infos {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t
                    ?? (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let num = info[kCGWindowNumber as String] as? Int
                    ?? (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let layer = info[kCGWindowLayer as String] as? Int
                    ?? (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0
            else { continue }
            result[pid, default: []].append(num)
        }
        return result
    }


    public func scanAll() {
        let previousManaged = managed
        lastScanTrusted = Self.isTrusted
        if !lastScanTrusted {
            NSLog("ALWM AX: Accessibility NOT trusted — window management disabled until granted")
        }

        let cgByPid = cgWindowNumbersByPID()
        var nextAX: [WindowID: AXWindow] = [:]
        var nextManaged: [WindowID: ManagedWindow] = [:]
        var appsSeen = 0
        var rawWindows = 0
        var skippedNoNumber = 0
        var skippedFilter = 0

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        appsSeen = apps.count

        for app in apps {
            let pid = app.processIdentifier
            if app.bundleIdentifier == "dev.alwm.ALWM" { continue }
            observe(pid: pid)

            let appEl = AXUIElementCreateApplication(pid)
            var windowsValue: AnyObject?
            let copyStatus = AXUIElementCopyAttributeValue(
                appEl,
                kAXWindowsAttribute as CFString,
                &windowsValue
            )
            guard copyStatus == .success else { continue }

            guard let windows = windowsValue as? [AXUIElement] else { continue }

            var cgPool = cgByPid[pid] ?? []
            for winEl in windows {
                rawWindows += 1
                let axProbe = AXWindow(
                    id: WindowID(pid: pid, windowNumber: -1),
                    element: winEl,
                    pid: pid
                )
                guard axProbe.isStandardWindow else {
                    skippedFilter += 1
                    continue
                }

                let num: Int
                if let n = readWindowNumber(winEl) {
                    num = n
                } else if let existing = axWindows.first(where: { CFEqual($0.value.element, winEl) })?.key {
                    // Keep prior id for this AX element (stable across rescans).
                    num = existing.windowNumber
                } else if !cgPool.isEmpty {
                    num = cgPool.removeFirst()
                } else {
                    // Stable for the life of the AXUIElement — never use list index.
                    num = Int(CFHash(winEl) & 0x7FFF_FFFF)
                    skippedNoNumber += 1
                }

                let id = WindowID(pid: pid, windowNumber: num)
                let ax = AXWindow(id: id, element: winEl, pid: pid)
                nextAX[id] = ax
                nextManaged[id] = ManagedWindow(
                    id: id,
                    title: ax.resolvedTitle(),
                    bundleID: app.bundleIdentifier,
                    appName: app.localizedName ?? "App",
                    frame: ax.frame,
                    isFloating: ax.prefersFloating
                )
                observeTitle(on: winEl, pid: pid, token: id.token)
            }
        }

        lastScanAppCount = appsSeen
        lastScanRawWindowCount = rawWindows
        lastScanAcceptedCount = nextManaged.count

        if nextManaged.count == 0 {
            NSLog(
                "ALWM AX: scan empty (trusted=%@ apps=%d rawWindows=%d skippedFilter=%d missingNumber≈%d)",
                lastScanTrusted ? "yes" : "no",
                appsSeen,
                rawWindows,
                skippedFilter,
                skippedNoNumber
            )
        } else if nextManaged.count != managed.count {
            NSLog("ALWM AX: tracking %d windows", nextManaged.count)
        }

        axWindows = nextAX
        managed = nextManaged
        let liveTokens = Set(nextAX.keys.map(\.token))
        titleObservedTokens = titleObservedTokens.intersection(liveTokens)
        publishIfNeeded(previousManaged: previousManaged)
    }


    /// Update a single window title without a full AX rescan (Electron apps change titles often).
    func refreshTitle(for id: WindowID) {
        guard let ax = axWindows[id], var win = managed[id] else { return }
        let next = ax.resolvedTitle()
        guard next != win.title else { return }
        win.title = next
        managed[id] = win
        delegate?.axTrackerWindowTitleDidChange(id, window: win)
    }


    func publish() {
        delegate?.axTrackerDidUpdateWindows(Array(managed.values), axWindows: axWindows)
    }


    /// Avoid full ingest when a rescan only refreshed titles on the same window set.
    func publishIfNeeded(previousManaged: [WindowID: ManagedWindow]) {
        let prevKeys = Set(previousManaged.keys)
        let nextKeys = Set(managed.keys)
        guard prevKeys == nextKeys else {
            publish()
            return
        }
        var titleOnly = false
        for (id, win) in managed {
            guard let prev = previousManaged[id] else {
                publish()
                return
            }
            if prev.frame != win.frame
                || prev.bundleID != win.bundleID
                || prev.appName != win.appName
                || prev.isFloating != win.isFloating
                || prev.isIgnored != win.isIgnored
                || prev.isScratchpad != win.isScratchpad {
                publish()
                return
            }
            if prev.title != win.title {
                titleOnly = true
            }
        }
        guard titleOnly else { return }
        for (id, win) in managed where previousManaged[id]?.title != win.title {
            delegate?.axTrackerWindowTitleDidChange(id, window: win)
        }
    }


    @objc func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        observe(pid: app.processIdentifier)
        scheduleScanAll(delay: 0.35)
    }


    @objc func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if let source = runLoopSources.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        observers.removeValue(forKey: pid)
        let gone = axWindows.keys.filter { $0.pid == pid }
        for id in gone {
            axWindows.removeValue(forKey: id)
            managed.removeValue(forKey: id)
            titleObservedTokens.remove(id.token)
        }
        publish()
    }
}

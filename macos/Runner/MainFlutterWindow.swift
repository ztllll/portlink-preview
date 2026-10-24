import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var diagnosticChannel: FlutterMethodChannel?
  private var diagnosticCloseObserver: NSObjectProtocol?
  private var diagnosticCloseCount = 0

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: false)
    self.orderOut(nil)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Lifecycle diagnostics have no configuration, credential or network access.
    // Fixture-argument-gated interaction methods below exercise this process
    // only. Normal UI never invokes them; snapshot itself remains read-only.
    diagnosticCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: self, queue: .main
    ) { [weak self] _ in self?.diagnosticCloseCount += 1 }
    diagnosticChannel = FlutterMethodChannel(
      name: "dev.portlink/window_diagnostics", binaryMessenger: flutterViewController.engine.binaryMessenger)
    diagnosticChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      func trayButtons(in view: NSView) -> [NSStatusBarButton] {
        var found = (view as? NSStatusBarButton).map { [$0] } ?? []
        for child in view.subviews { found += trayButtons(in: child) }
        return found
      }
      // Interaction injection exists only in the dedicated fixture smoke process.
      // It posts AppKit events inside this process, never global mouse events.
      if call.method == "exerciseTrayMenu" || call.method == "exerciseTrayLeftClick" {
        guard CommandLine.arguments.contains(where: { $0.hasPrefix("--fixture-port=") }),
              CommandLine.arguments.contains(where: { $0.hasPrefix("--fingerprint=") }),
              let arguments = call.arguments as? [String: Any],
              let address = arguments["menuAddress"] as? NSNumber,
              let pointer = UnsafeRawPointer(bitPattern: address.uintValue),
              let button = NSApp.windows.compactMap({ $0.contentView }).flatMap({ trayButtons(in: $0) }).first,
              let buttonWindow = button.window else {
          result(FlutterError(code: "smoke_only", message: "Dedicated native fixture process required", details: nil)); return
        }
        let menu = Unmanaged<NSMenu>.fromOpaque(pointer).takeUnretainedValue()
        let rightClick = call.method == "exerciseTrayMenu"
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let startedAt = ProcessInfo.processInfo.systemUptime
        var opened = false
        var selected = false
        var eventObserved = false
        let eventMonitor = NSEvent.addLocalMonitorForEvents(matching: rightClick ? [.rightMouseUp] : [.leftMouseUp]) { event in
          if event.windowNumber == buttonWindow.windowNumber { eventObserved = true }
          return event
        }
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main) { _ in opened = true }
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
          if rightClick && opened && !selected {
            if let index = menu.items.firstIndex(where: { $0.title == "管理服务器…" && $0.isEnabled }) {
              selected = true
              menu.performActionForItem(at: index)
              menu.cancelTrackingWithoutAnimation()
            }
          }
          if (!rightClick && ProcessInfo.processInfo.systemUptime - startedAt > 0.3) || selected || ProcessInfo.processInfo.systemUptime - startedAt > 4 {
            timer.invalidate()
            menu.cancelTrackingWithoutAnimation()
            NotificationCenter.default.removeObserver(observer)
            if let eventMonitor = eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            DispatchQueue.main.async { result(["rightClick": rightClick, "eventObserved": eventObserved, "buttonTarget": button.target.map { String(describing: type(of: $0)) } ?? "nil", "buttonAction": button.action.map { NSStringFromSelector($0) } ?? "nil", "buttonVisible": !button.isHidden, "buttonFrame": NSStringFromRect(button.frame), "menuTrackingOpened": opened, "manageActionSelected": selected, "windowVisible": self.isVisible]) }
          }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        DispatchQueue.main.async {
          NSApp.activate(ignoringOtherApps: true)
          let type: NSEvent.EventType = rightClick ? .rightMouseUp : .leftMouseUp
          let mask: NSEvent.EventTypeMask = rightClick ? .rightMouseUp : .leftMouseUp
          if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: buttonWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
            // Dequeue through NSApplication to establish currentEvent, as AppKit
            // does for a real click. Direct sendEvent alone leaves currentEvent nil.
            NSApp.postEvent(event, atStart: true)
            if NSApp.nextEvent(matching: mask, until: Date(timeIntervalSinceNow: 0.2), inMode: .default, dequeue: true) != nil {
              eventObserved = NSApp.currentEvent?.type == type
              if let action = button.action {
                NSApp.sendAction(action, to: button.target, from: button)
              }
            }
          }
        }
        return
      }
      guard call.method == "snapshot" else { result(FlutterMethodNotImplemented); return }
      var trayImages: [[String: Any]] = []
      for window in NSApp.windows {
        guard let content = window.contentView else { continue }
        for button in trayButtons(in: content) {
          guard let image = button.image else { continue }
          var red = 0, green = 0
          if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            for y in 0..<min(bitmap.pixelsHigh, 256) {
              for x in 0..<min(bitmap.pixelsWide, 256) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                if color.redComponent > 0.5 && color.redComponent > color.greenComponent * 1.4 { red += 1 }
                if color.greenComponent > 0.4 && color.greenComponent > color.redComponent * 1.4 { green += 1 }
              }
            }
          }
          trayImages.append(["width": image.size.width, "height": image.size.height,
                             "isTemplate": image.isTemplate, "redPixels": red, "greenPixels": green])
        }
      }
      result(["trayImages": trayImages, "activationPolicy": NSApp.activationPolicy().rawValue,
              "lsuiElement": Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false,
              "willCloseCount": self.diagnosticCloseCount,
              "delegateClass": self.delegate.map { String(describing: type(of: $0)) } ?? "nil",
              "windowNumber": self.windowNumber, "visible": self.isVisible])
    }

    super.awakeFromNib()
    // FlutterViewController normally starts its engine from viewWillAppear.
    // A menu-bar utility never shows this window at launch, so explicitly run
    // the already-attached engine once; do not flash a window just to bootstrap.
    _ = flutterViewController.view
    if !flutterViewController.engine.run(withEntrypoint: nil) {
      self.makeKeyAndOrderFront(nil)
    }
  }

  deinit {
    if let observer = diagnosticCloseObserver { NotificationCenter.default.removeObserver(observer) }
  }
}

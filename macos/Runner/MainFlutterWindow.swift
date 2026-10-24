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
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Read-only lifecycle diagnostics. No configuration, credentials or network
    // access; a separate verification entrypoint uses it to distinguish a true
    // close from close-to-tray hiding. Normal UI does not invoke this channel.
    diagnosticCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: self, queue: .main
    ) { [weak self] _ in self?.diagnosticCloseCount += 1 }
    diagnosticChannel = FlutterMethodChannel(
      name: "dev.portlink/window_diagnostics", binaryMessenger: flutterViewController.engine.binaryMessenger)
    diagnosticChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      guard call.method == "snapshot" else { result(FlutterMethodNotImplemented); return }
      func trayButtons(in view: NSView) -> [NSStatusBarButton] {
        var found = (view as? NSStatusBarButton).map { [$0] } ?? []
        for child in view.subviews { found += trayButtons(in: child) }
        return found
      }
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
      result(["trayImages": trayImages, "willCloseCount": self.diagnosticCloseCount,
              "delegateClass": self.delegate.map { String(describing: type(of: $0)) } ?? "nil",
              "windowNumber": self.windowNumber, "visible": self.isVisible])
    }

    super.awakeFromNib()
  }

  deinit {
    if let observer = diagnosticCloseObserver { NotificationCenter.default.removeObserver(observer) }
  }
}

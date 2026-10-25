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
      result(["willCloseCount": self.diagnosticCloseCount,
              "delegateClass": self.delegate.map { String(describing: type(of: $0)) } ?? "nil",
              "windowNumber": self.windowNumber, "visible": self.isVisible])
    }

    super.awakeFromNib()
  }

  deinit {
    if let observer = diagnosticCloseObserver { NotificationCenter.default.removeObserver(observer) }
  }
}

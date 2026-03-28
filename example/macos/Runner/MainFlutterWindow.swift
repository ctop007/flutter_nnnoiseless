import Cocoa
import AVFoundation
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var audioPlayer: AVAudioPlayer?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "example.flutter_nnnoiseless/audio_preview",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "playFile":
        guard
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
        else {
          result(FlutterError(code: "invalid_path", message: "Audio path is missing.", details: nil))
          return
        }

        do {
          self?.audioPlayer?.stop()
          self?.audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
          self?.audioPlayer?.prepareToPlay()
          self?.audioPlayer?.play()
          result(nil)
        } catch {
          result(FlutterError(code: "playback_failed", message: error.localizedDescription, details: nil))
        }

      case "stopPlayback":
        self?.audioPlayer?.stop()
        self?.audioPlayer = nil
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}

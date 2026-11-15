// swiftc -D WINDOWSHARE_TEST -parse-as-library -o /tmp/ws-offscreen Scripts/verify-offscreen-selection.swift host/Sources/{CaptureController,InputController,PairingSession,ViewerPage,EntryConfiguration,AgentRequest,CLI}.swift && /tmp/ws-offscreen
import Foundation
@main struct OffscreenSelectionTest {
 static func main() {
  precondition(CaptureController.selectableWindow(onScreen: true, layer: 0, includeOffscreen: false))
  precondition(!CaptureController.selectableWindow(onScreen: false, layer: 0, includeOffscreen: false))
  precondition(CaptureController.selectableWindow(onScreen: false, layer: 0, includeOffscreen: true))
  precondition(!CaptureController.selectableWindow(onScreen: false, layer: 20, includeOffscreen: true))
  precondition(CLITarget.windowID(42).includesOffscreen)
  precondition(!CLITarget.app("Ego").includesOffscreen)
  precondition(!CLITarget.titleContains("fixture").includesOffscreen)
  print("PASS menu stays on-screen; exact Agent ID can select offscreen normal-layer window")
 }
}

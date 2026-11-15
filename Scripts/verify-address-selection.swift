// swiftc host/Sources/EntryConfiguration.swift Scripts/verify-address-selection.swift -o /tmp/ws-address && /tmp/ws-address
import Foundation
@main struct AddressSelectionTest {
 static func main() {
  let ts = "http://100.64.0.2:8777/", lan = "http://192.168.1.2:8777/"
  var probes: [String] = []
  precondition(EntryConfiguration.orderedReachable([lan,ts], probe: { probes.append($0); return true }) == [ts,lan])
  precondition(probes == [ts,lan])
  precondition(EntryConfiguration.orderedReachable([ts,lan], probe: { $0 == lan }) == [lan])
  precondition(EntryConfiguration.orderedReachable([ts,lan], preference: "lan", probe: { _ in true }) == [lan,ts])
  precondition(EntryConfiguration.orderedReachable([ts,lan], preference: "lan", probe: { $0 == ts }) == [ts])
  precondition(EntryConfiguration.orderedReachable([ts,lan], probe: { _ in false }).isEmpty)
  let suite = "windowshare.test." + UUID().uuidString
  let defaults = UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  precondition(EntryConfiguration.entryPreference(defaults:defaults) == "tailscale")
  EntryConfiguration.saveEntryPreference("lan",defaults:defaults)
  precondition(EntryConfiguration.entryPreference(defaults:UserDefaults(suiteName:suite)!) == "lan")
  EntryConfiguration.saveEntryPreference("tailscale",defaults:defaults)
  precondition(EntryConfiguration.entryPreference(defaults:defaults) == "tailscale")
  print("PASS Tailscale preferred, LAN fallback, persisted preference override/reset, neither reachable")
 }
}

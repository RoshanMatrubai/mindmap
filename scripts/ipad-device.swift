// Picks the iPad for `make ipad-install`, run with `swift scripts/ipad-device.swift <json> [device]`.
// <json> is `xcrun devicectl list devices --json-output` output; [device] is a name or hardware
// UDID. Prints "<hardware udid> <CoreDevice identifier>": xcodebuild's -destination id is the
// UDID, `devicectl device install app --device` takes the identifier. Exits 1 with a message when
// no iPad (or several, without [device]) is connected, or Developer Mode is off. Simulators are
// in the same list (Xcode 26 and later) and are never candidates.
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]),
  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
  let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]]
else { fail("couldn't read the device list from devicectl") }
let wanted = args.count >= 3 && !args[2].isEmpty ? args[2] : nil

func value(_ device: [String: Any], _ group: String, _ key: String) -> String? {
  (device[group] as? [String: Any])?[key] as? String
}
func name(_ device: [String: Any]) -> String {
  value(device, "deviceProperties", "name") ?? "unnamed iPad"
}
func udid(_ device: [String: Any]) -> String? { value(device, "hardwareProperties", "udid") }

/// A real device, not a simulator. `reality` ("physical" or "simulated") is the direct flag:
/// under `properties.hardware` (Xcode 27's replacement dictionary) or `hardwareProperties`.
/// Without it, a simulator's transport is "sameMachine" (it runs on this Mac).
func physical(_ device: [String: Any]) -> Bool {
  let hardware = (device["properties"] as? [String: Any])?["hardware"] as? [String: Any]
  if let reality = hardware?["reality"] as? String ?? value(device, "hardwareProperties", "reality")
  {
    return reality == "physical"
  }
  let connection = (device["properties"] as? [String: Any])?["connection"] as? [String: Any]
  let transport =
    connection?["transportType"] as? String
    ?? value(device, "connectionProperties", "transportType")
  return transport != "sameMachine"
}

let ipads = devices.filter {
  value($0, "hardwareProperties", "deviceType") == "iPad" && physical($0)
}
// Connected now (a cable or the same network), not just paired at some point.
let connected = ipads.filter {
  value($0, "connectionProperties", "tunnelState") != "unavailable"
    && value($0, "connectionProperties", "transportType") != nil
}
let candidates: [[String: Any]]
if let wanted {
  candidates = ipads.filter {
    name($0) == wanted || udid($0)?.caseInsensitiveCompare(wanted) == .orderedSame
  }
  if candidates.isEmpty {
    let known = ipads.map(name).joined(separator: ", ")
    fail(
      "no iPad named or with UDID \"\(wanted)\"" + (known.isEmpty ? "" : " (paired: \(known))"))
  }
} else {
  candidates = connected
  if candidates.isEmpty {
    fail("no iPad connected: connect it with a cable, unlock it and tap Trust")
  }
  if candidates.count > 1 {
    fail(
      "several iPads are connected (\(candidates.map(name).joined(separator: ", "))); "
        + "pick one with DEVICE=\"<name>\"")
  }
}
let device = candidates[0]
if let mode = value(device, "deviceProperties", "developerModeStatus"), mode != "enabled" {
  fail(
    "Developer Mode is off on \(name(device)): Settings > Privacy & Security > Developer Mode, then restart it"
  )
}
guard let hardware = udid(device), let identifier = device["identifier"] as? String else {
  fail("devicectl lists \(name(device)) without a UDID or identifier; is it unlocked and trusted?")
}
FileHandle.standardError.write(Data("installing on \(name(device))\n".utf8))
print(hardware, identifier)

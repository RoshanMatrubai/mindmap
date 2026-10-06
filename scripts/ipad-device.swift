// Picks the iPad for `make ipad-install`, run with `swift scripts/ipad-device.swift <json> [name]`.
// <json> is `xcrun devicectl list devices --json-output` output. Prints the device identifier;
// exits 1 with a message when no iPad is connected or Developer Mode is off.
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]),
  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
  let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]]
else {
  FileHandle.standardError.write(Data("couldn't read the device list from devicectl\n".utf8))
  exit(1)
}
let wanted = args.count >= 3 && !args[2].isEmpty ? args[2] : nil

func value(_ device: [String: Any], _ group: String, _ key: String) -> String? {
  (device[group] as? [String: Any])?[key] as? String
}

let ipads = devices.filter { value($0, "hardwareProperties", "deviceType") == "iPad" }
let named = ipads.filter { wanted == nil || value($0, "deviceProperties", "name") == wanted }
// A device the Mac can reach now (cable or the same network), not just one paired earlier.
let reachable = named.filter {
  let state = value($0, "connectionProperties", "tunnelState")
  return state != "unavailable" && value($0, "connectionProperties", "transportType") != nil
}
guard let device = reachable.first ?? named.first else {
  let message =
    wanted.map { "no iPad named \"\($0)\" (DEVICE=<name> must match its name in Finder)" }
    ?? "no iPad found: connect it with a cable, unlock it and tap Trust"
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}
let name = value(device, "deviceProperties", "name") ?? "the iPad"
if let mode = value(device, "deviceProperties", "developerModeStatus"), mode != "enabled" {
  FileHandle.standardError.write(
    Data(
      "Developer Mode is off on \(name): Settings > Privacy & Security > Developer Mode, then restart it\n"
        .utf8))
  exit(1)
}
guard let identifier = device["identifier"] as? String else { exit(1) }
FileHandle.standardError.write(Data("installing on \(name)\n".utf8))
print(identifier)

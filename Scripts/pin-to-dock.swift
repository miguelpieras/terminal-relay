import CoreFoundation
import Foundation

let applicationURL = URL(fileURLWithPath: "/Applications/Terminal Relay.app", isDirectory: true)
let bundleIdentifier = "com.miguelpieras.TerminalRelay"
let preferencesDomain = "com.apple.dock" as CFString
let applicationsKey = "persistent-apps" as CFString

guard FileManager.default.fileExists(atPath: applicationURL.path) else {
    fputs("Terminal Relay is not installed.\n", stderr)
    exit(1)
}

var applications = CFPreferencesCopyAppValue(applicationsKey, preferencesDomain) as? [[String: Any]] ?? []

func isTerminalRelayItem(_ item: [String: Any]) -> Bool {
    guard let tileData = item["tile-data"] as? [String: Any] else { return false }

    if tileData["bundle-identifier"] as? String == bundleIdentifier {
        return true
    }

    guard
        let fileData = tileData["file-data"] as? [String: Any],
        let urlString = fileData["_CFURLString"] as? String
    else {
        return false
    }

    return urlString == applicationURL.absoluteString
}

let bookmark = try applicationURL.bookmarkData(
    options: .minimalBookmark,
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)

let tileData: [String: Any] = [
    "book": bookmark,
    "bundle-identifier": bundleIdentifier,
    "dock-extra": 0,
    "file-data": [
        "_CFURLString": applicationURL.absoluteString,
        "_CFURLStringType": 15
    ],
    "file-label": "Terminal Relay",
    "file-type": 41,
    "is-beta": 0
]

let matchingIndices = applications.indices.filter { isTerminalRelayItem(applications[$0]) }
let guid = matchingIndices.first.flatMap { applications[$0]["GUID"] }
    ?? Int.random(in: 1...Int(UInt32.max))
let refreshedItem: [String: Any] = [
    "GUID": guid,
    "tile-data": tileData,
    "tile-type": "file-tile"
]

let result: String
if let firstIndex = matchingIndices.first {
    applications[firstIndex] = refreshedItem
    for duplicateIndex in matchingIndices.dropFirst().reversed() {
        applications.remove(at: duplicateIndex)
    }
    result = "refreshed"
} else {
    applications.append(refreshedItem)
    result = "added"
}

CFPreferencesSetAppValue(applicationsKey, applications as CFArray, preferencesDomain)

guard CFPreferencesAppSynchronize(preferencesDomain) else {
    fputs("The Dock preferences could not be saved.\n", stderr)
    exit(1)
}

print(result)

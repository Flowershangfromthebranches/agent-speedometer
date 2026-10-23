import Foundation
import Darwin

// Publish a fully built bundle without exposing an empty/partial .app to Finder.
let manager = FileManager.default
let staged = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
if manager.fileExists(atPath: destination.path) {
    guard renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    // The old generated bundle is now at the staging path.
    try manager.removeItem(at: staged)
} else {
    try manager.moveItem(at: staged, to: destination)
}

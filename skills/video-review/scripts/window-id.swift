// Resolve window geometry by name for `screencapture -R`, and report whether each window is
// actually on the CURRENT Space.
//
// WHY THIS EXISTS. Region capture (`screencapture -R <rect>`) only ever sees the current Space.
// When the target window lives on another desktop, `-R` returns the wallpaper behind it with a
// ZERO exit code -- a plausible screenshot of entirely the wrong thing. That silent failure is the
// bug this helper makes detectable.
//
// WHY NOT CAPTURE BY WINDOW ID. `screencapture -l <id>` would sidestep Spaces entirely by reading
// the window's own backing store. It is broken on macOS 15 (verified on 15.7.7): every window,
// including ones on the active Space, fails with "could not create image from window". Apple moved
// window capture to ScreenCaptureKit and the legacy path no longer works. Third-party window-id
// tools (e.g. GetWindowID) hit the same wall, because the capture still goes through `-l`.
// So: resolve geometry here, verify the window is on-screen, and let the shell use `-R`.
//
// Prints one match per line, largest window first:
//     <id>\t<owner>\t<x>,<y>,<w>,<h>\t<onscreen|offscreen>\t<title>
//
// Window TITLES need Screen Recording permission and are often empty even with it (macOS
// attributes the grant to the signed parent app). Owner name and size are the reliable match keys.

import CoreGraphics
import Foundation

let firstArg = CommandLine.arguments.dropFirst().first ?? ""

// Without Screen Recording permission, macOS does not fail loudly -- it quietly returns a picture
// of the DESKTOP WALLPAPER with a zero exit code, hiding every other app's window. The other tell
// is that every window title below comes back empty. Preflight so callers can refuse up front
// instead of shipping a screenshot of nothing. Exit 3 == denied.
if firstArg == "--check-perms" {
    let granted = CGPreflightScreenCaptureAccess()
    print(granted ? "granted" : "denied")
    exit(granted ? 0 : 3)
}

let needle = firstArg

// .optionAll is rawValue 0, so this means "every window on every Space, minus desktop/wallpaper".
// Do NOT add .optionOnScreenOnly here -- that is the separate query below.
let allOptions: CGWindowListOption = [.excludeDesktopElements]
let onScreenOptions: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]

guard let windows = CGWindowListCopyWindowInfo(allOptions, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("window-id: CGWindowListCopyWindowInfo failed\n".utf8))
    exit(1)
}

// Windows the window server currently considers on-screen. A window on another Space is absent
// here even though it is present in the full list -- which is exactly the distinction that makes
// the wallpaper failure detectable in advance.
let onScreenIDs: Set<Int> = {
    guard let list = CGWindowListCopyWindowInfo(onScreenOptions, kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return Set(list.compactMap { $0[kCGWindowNumber as String] as? Int })
}()

struct Hit {
    let id: Int
    let owner: String
    let title: String
    let x: Int, y: Int, width: Int, height: Int
    let onScreen: Bool
}

var hits: [Hit] = []

for win in windows {
    // Layer 0 is ordinary application windows. The Dock, menu-bar extras and overlay HUDs sit on
    // higher layers and would otherwise clutter every result.
    guard (win[kCGWindowLayer as String] as? Int) == 0,
          let id = win[kCGWindowNumber as String] as? Int,
          let bounds = win[kCGWindowBounds as String] as? [String: Any] else { continue }

    let owner = win[kCGWindowOwnerName as String] as? String ?? ""
    let title = win[kCGWindowName as String] as? String ?? ""

    let x = Int(bounds["X"] as? Double ?? 0)
    let y = Int(bounds["Y"] as? Double ?? 0)
    let width = Int(bounds["Width"] as? Double ?? 0)
    let height = Int(bounds["Height"] as? Double ?? 0)

    // Drop shadow/tooltip slivers that are technically layer-0 windows.
    if width < 40 || height < 40 { continue }

    let matches = needle.isEmpty
        || owner.localizedCaseInsensitiveContains(needle)
        || title.localizedCaseInsensitiveContains(needle)
    guard matches else { continue }

    hits.append(Hit(id: id, owner: owner, title: title,
                    x: x, y: y, width: width, height: height,
                    onScreen: onScreenIDs.contains(id)))
}

// Largest first: the main window is nearly always the biggest, so a caller taking the first hit
// gets the useful one rather than a palette or inspector panel.
hits.sort { $0.width * $0.height > $1.width * $1.height }

for hit in hits {
    let state = hit.onScreen ? "onscreen" : "offscreen"
    print("\(hit.id)\t\(hit.owner)\t\(hit.x),\(hit.y),\(hit.width),\(hit.height)\t\(state)\t\(hit.title)")
}

import Foundation
import AppKit

// MARK: - UpdateChecker
//
// Checks https://api.github.com/repos/CheBhoganadhuni/AndroidConnect/releases/latest
// for a newer version.  If found, downloads the first .zip asset, extracts it to /tmp,
// writes a tiny shell script that (after this process exits) moves the new .app into place
// and relaunches it, then calls NSApp.terminate.
//
// Publishing a release:
//   1. Build with build_mac.sh
//   2. zip -r AndroidConnect-v1.x.x.zip AndroidConnect.app
//   3. gh release create v1.x.x AndroidConnect-v1.x.x.zip --title "v1.x.x" --notes "…"
//   4. Bump AppVersion.current to match before the next build.

final class UpdateChecker {

    static let shared = UpdateChecker()
    private init() {}

    private let apiURL = URL(string:
        "https://api.github.com/repos/CheBhoganadhuni/AndroidConnect/releases/latest")!

    // MARK: - Entry point

    /// Call from the main thread (e.g. version button click).
    /// `onBeforeResult` is called on the main thread just before the result alert appears —
    /// use it to close the popover / restore button state so the alert appears cleanly.
    func checkForUpdates(onBeforeResult: (() -> Void)? = nil) {
        fetchLatest { [weak self] result in
            DispatchQueue.main.async {
                onBeforeResult?()
                // Small pause so popover dismiss animation finishes before alert appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.handleResult(result)
                }
            }
        }
    }

    // MARK: - Fetch

    private struct Release {
        let tag: String        // e.g. "v1.2.0"
        let version: String    // e.g. "1.2.0"
        let notes: String
        let zipURL: URL?
    }

    private func fetchLatest(completion: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completion(.failure(ACError("Invalid server response"))); return
            }
            // GitHub returns {"message":"Not Found"} when no releases exist yet
            if let msg = json["message"] as? String {
                completion(.failure(ACError(msg))); return
            }
            guard let tag = json["tag_name"] as? String else {
                completion(.failure(ACError("Missing tag_name in release"))); return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes   = json["body"] as? String ?? ""
            var zipURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for a in assets {
                    if let name = a["name"] as? String, name.hasSuffix(".zip"),
                       let u    = a["browser_download_url"] as? String {
                        zipURL = URL(string: u); break
                    }
                }
            }
            completion(.success(Release(tag: tag, version: version, notes: notes, zipURL: zipURL)))
        }.resume()
    }

    // MARK: - Result handling

    private func handleResult(_ result: Result<Release, Error>) {
        switch result {
        case .failure(let err):
            alert("Update check failed", info: err.localizedDescription, style: .warning)

        case .success(let release):
            guard isNewer(release.version, than: AppVersion.current) else {
                alert("You're up to date!",
                      info: "Android Connect \(AppVersion.display) is the latest version.",
                      style: .informational)
                return
            }
            promptInstall(release)
        }
    }

    private func promptInstall(_ release: Release) {
        let a = NSAlert()
        a.messageText     = "Update available: \(release.tag)"
        a.informativeText = release.notes.isEmpty
            ? "A new version of Android Connect is available."
            : release.notes
        a.alertStyle = .informational
        a.addButton(withTitle: "Download & Restart")
        a.addButton(withTitle: "Later")

        guard a.runModal() == .alertFirstButtonReturn else { return }

        if let url = release.zipURL {
            download(from: url, newVersion: release.tag)
        } else {
            // No zip asset — open releases page so user can grab it manually
            NSWorkspace.shared.open(
                URL(string: "https://github.com/CheBhoganadhuni/AndroidConnect/releases/latest")!)
        }
    }

    // MARK: - Download + install

    private func download(from url: URL, newVersion: String) {
        // Show a non-blocking progress window while downloading
        let win = makeProgressWindow(title: "Downloading \(newVersion)…")
        win.makeKeyAndOrderFront(nil)

        URLSession.shared.downloadTask(with: url) { [weak self] tmpURL, _, error in
            DispatchQueue.main.async {
                win.orderOut(nil)
                guard let self else { return }
                if let error {
                    self.alert("Download failed", info: error.localizedDescription, style: .critical)
                    return
                }
                guard let tmpURL else {
                    self.alert("Download failed", info: "No file received.", style: .critical)
                    return
                }
                self.install(zipAt: tmpURL)
            }
        }.resume()
    }

    private func install(zipAt tmpURL: URL) {
        let fm   = FileManager.default
        let tmp  = URL(fileURLWithPath: NSTemporaryDirectory())
        let zip  = tmp.appendingPathComponent("AndroidConnect_update.zip")
        let extr = tmp.appendingPathComponent("AndroidConnect_update")
        let appSrc = Bundle.main.bundleURL   // current .app path (wherever user installed it)

        do {
            try? fm.removeItem(at: zip)
            try fm.moveItem(at: tmpURL, to: zip)

            // Write a shell script that runs AFTER we quit:
            //   1. Unzip into a temp dir
            //   2. Find the first .app inside
            //   3. Remove the old .app and move the new one in
            //   4. Relaunch
            let script = """
            #!/bin/bash
            sleep 1.5
            rm -rf '\(extr.path)'
            unzip -q '\(zip.path)' -d '\(extr.path)'
            NEW="$(find '\(extr.path)' -maxdepth 2 -name '*.app' | head -1)"
            if [ -z "$NEW" ]; then
                osascript -e 'display alert "Update failed" message "Could not find .app in downloaded zip."'
                exit 1
            fi
            rm -rf '\(appSrc.path)'
            cp -R "$NEW" '\(appSrc.path)'
            open '\(appSrc.path)'
            rm -rf '\(zip.path)' '\(extr.path)' "$0"
            """

            let scriptURL = tmp.appendingPathComponent("ac_install.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                 ofItemAtPath: scriptURL.path)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scriptURL.path]
            try p.run()

            NSApp.terminate(nil)

        } catch {
            alert("Install failed", info: error.localizedDescription, style: .critical)
        }
    }

    // MARK: - Helpers

    /// Returns true if `a` is strictly newer than `b` (e.g. "1.1.0" > "1.0.0").
    private func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let av = i < pa.count ? pa[i] : 0
            let bv = i < pb.count ? pb[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    @discardableResult
    private func alert(_ title: String, info: String, style: NSAlert.Style) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText     = title
        a.informativeText = info
        a.alertStyle      = style
        a.addButton(withTitle: "OK")
        return a.runModal()
    }

    private func makeProgressWindow(title: String) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
                            styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Android Connect"
        panel.isFloatingPanel = true
        panel.center()

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: panel.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor),
        ])
        return panel
    }
}

// MARK: - Tiny error type

private struct ACError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

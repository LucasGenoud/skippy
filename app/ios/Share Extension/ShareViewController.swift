//
//  ShareViewController.swift
//  Share Extension
//
//  Entry point for the iOS share sheet. We subclass the vendored
//  RSIShareViewController (same target — no `import receive_sharing_intent`,
//  since this project is SPM-only with no CocoaPods to link the plugin into the
//  extension). shouldAutoRedirect() == true means no compose UI: the shared
//  content is written to the shared App Group and the host app is opened, which
//  then creates the note silently. See lib/state/share_intake_io.dart.
//
import UIKit

class ShareViewController: RSIShareViewController {
    override func shouldAutoRedirect() -> Bool {
        return true
    }
}

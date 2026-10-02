//
//  LaunchWindowAnchor.swift
//  Project Planner
//
//  Reports when this view is on screen. It does not create a window, hide a window,
//  or call makeKeyAndVisible. Those calls during launch left a blank window and then crashed.
//

import SwiftUI
import UIKit

struct LaunchWindowAnchor: UIViewControllerRepresentable {
    var onReady: () -> Void

    func makeUIViewController(context: Context) -> LaunchWindowAnchorController {
        let controller = LaunchWindowAnchorController()
        controller.onReady = onReady
        return controller
    }

    func updateUIViewController(_ controller: LaunchWindowAnchorController, context: Context) {
        controller.onReady = onReady
    }
}

final class LaunchWindowAnchorController: UIViewController {
    var onReady: (() -> Void)?
    private var didClaim = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didClaim else { return }
        didClaim = true
        // After this appearance turn. Setting SwiftUI state inside the appearance
        // callback blanks the window and can crash.
        DispatchQueue.main.async { [onReady] in
            print("🔥🔥🔥 DEBUG: PP_LAUNCH_WINDOW claimed")
            onReady?()
        }
    }
}

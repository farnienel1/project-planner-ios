//
//  LaunchWindowAnchor.swift
//  Project Planner
//
//  SwiftUI can finish launching on a window that is not the one on screen.
//  An empty window in front is plain white, while Home still logs that it appeared.
//  This claims only the window that already hosts this view. It does not create a window.
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
        controller.claimHostWindow()
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
        claimHostWindow()
    }

    func claimHostWindow() {
        guard let window = view.window else {
            print("🔥🔥🔥 DEBUG: PP_LAUNCH_WINDOW none yet")
            return
        }
        window.backgroundColor = UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.071, green: 0.078, blue: 0.102, alpha: 1)
            }
            return UIColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1)
        }
        if window.isHidden {
            window.isHidden = false
        }
        let alreadyKey = window.isKeyWindow
        print("🔥🔥🔥 DEBUG: PP_LAUNCH_WINDOW key=\(alreadyKey)")
        if !alreadyKey {
            window.makeKey()
        }
        guard !didClaim else { return }
        didClaim = true
        onReady?()
    }
}

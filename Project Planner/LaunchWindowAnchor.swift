//
//  LaunchWindowAnchor.swift
//  Project Planner
//
//  SwiftUI can finish launching on a window that is not the one on screen.
//  An empty window in front is plain white (or black the next time it opens),
//  while Home still logs that it appeared.
//  This claims only the window that already hosts this view. It does not create a window.
//

import SwiftUI
import UIKit

struct LaunchWindowAnchor: UIViewControllerRepresentable {
    var coverVisible: Bool
    var onReady: () -> Void

    func makeUIViewController(context: Context) -> LaunchWindowAnchorController {
        let controller = LaunchWindowAnchorController()
        controller.onReady = onReady
        controller.coverVisible = coverVisible
        return controller
    }

    func updateUIViewController(_ controller: LaunchWindowAnchorController, context: Context) {
        controller.onReady = onReady
        controller.coverVisible = coverVisible
        controller.claimHostWindow()
    }
}

final class LaunchWindowAnchorController: UIViewController {
    var onReady: (() -> Void)?
    var coverVisible = true {
        didSet {
            guard oldValue != coverVisible else { return }
            updateCover()
        }
    }

    private var didClaim = false
    private var coverRemoval: DispatchWorkItem?

    static let coverTag = 91_027

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
        hideEmptySiblingWindows(of: window)
        window.backgroundColor = .white
        if window.isHidden {
            window.isHidden = false
        }
        ensureCover(on: window)
        let alreadyKey = window.isKeyWindow
        let rootName = String(describing: type(of: window.rootViewController as Any))
        print("🔥🔥🔥 DEBUG: PP_LAUNCH_WINDOW key=\(alreadyKey) frame=\(window.bounds) root=\(rootName)")
        // Only this window. Making every window key left the last empty one in front.
        if !alreadyKey {
            window.makeKeyAndVisible()
        }
        updateCover()
        guard !didClaim else { return }
        didClaim = true
        onReady?()
    }

    private func hideEmptySiblingWindows(of host: UIWindow) {
        guard let scene = host.windowScene else { return }
        for other in scene.windows where other !== host {
            let empty = other.rootViewController == nil
            print("🔥🔥🔥 DEBUG: PP_LAUNCH_OTHER key=\(other.isKeyWindow) hidden=\(other.isHidden) empty=\(empty)")
            if empty {
                other.isHidden = true
            }
        }
    }

    private func updateCover() {
        guard let window = view.window else { return }
        if coverVisible {
            coverRemoval?.cancel()
            coverRemoval = nil
            ensureCover(on: window)
            return
        }
        guard window.viewWithTag(Self.coverTag) != nil, coverRemoval == nil else { return }
        let removal = DispatchWorkItem { [weak self, weak window] in
            window?.viewWithTag(Self.coverTag)?.removeFromSuperview()
            window?.backgroundColor = UIColor { trait in
                if trait.userInterfaceStyle == .dark {
                    return UIColor(red: 0.071, green: 0.078, blue: 0.102, alpha: 1)
                }
                return UIColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1)
            }
            print("🔥🔥🔥 DEBUG: PP_LAUNCH_COVER off")
            self?.coverRemoval = nil
        }
        coverRemoval = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: removal)
    }

    private func ensureCover(on window: UIWindow) {
        if window.viewWithTag(Self.coverTag) != nil { return }
        let cover = UIView(frame: window.bounds)
        cover.tag = Self.coverTag
        cover.backgroundColor = .white
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let image = UIImage(named: "AppLogo") {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 120),
                imageView.heightAnchor.constraint(equalToConstant: 120)
            ])
            stack.addArrangedSubview(imageView)
        }

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)

        let label = UILabel()
        label.text = "Loading your jobs"
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = UIColor.black.withAlphaComponent(0.55)
        stack.addArrangedSubview(label)

        cover.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cover.centerYAnchor)
        ])
        window.addSubview(cover)
        print("🔥🔥🔥 DEBUG: PP_LAUNCH_COVER on")
    }
}

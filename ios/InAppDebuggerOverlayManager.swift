import UIKit

private let liquidGlassFloatingButtonAlpha: CGFloat = 0.86

final class PassThroughWindow: UIWindow {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard let rootView = rootViewController?.view else {
      return false
    }

    if rootViewController?.presentedViewController != nil {
      return super.point(inside: point, with: event)
    }

    for subview in rootView.subviews.reversed() where !subview.isHidden && subview.alpha > 0.01 {
      let converted = subview.convert(point, from: self)
      if subview.point(inside: converted, with: event) {
        return true
      }
    }
    return false
  }
}

final class InAppDebuggerFloatingButtonView: UIView {
  var onTap: (() -> Void)?
  private var panStart = CGPoint.zero
  private var viewStart = CGPoint.zero
  private lazy var button: UIButton = {
    let button = UIButton(type: .system)
    var config: UIButton.Configuration
    if #available(iOS 26.0, *) {
      config = .glass()
      button.alpha = liquidGlassFloatingButtonAlpha
    } else {
      config = .filled()
      config.baseBackgroundColor = UIColor(red: 0.12, green: 0.44, blue: 0.36, alpha: 1)
      config.baseForegroundColor = .white
    }
    config.cornerStyle = .capsule
    config.image = UIImage(systemName: "ladybug.fill")
    config.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
    button.configuration = config
    button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    return button
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    addSubview(button)
    addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    button.frame = bounds
  }

  @objc private func handleTap() {
    onTap?()
  }

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    guard let superview else {
      return
    }

    switch recognizer.state {
    case .began:
      panStart = recognizer.location(in: superview)
      viewStart = frame.origin
    case .changed:
      let point = recognizer.location(in: superview)
      let deltaX = point.x - panStart.x
      let deltaY = point.y - panStart.y
      var nextFrame = frame
      nextFrame.origin.x = max(0, min(superview.bounds.width - frame.width, viewStart.x + deltaX))
      nextFrame.origin.y = max(0, min(superview.bounds.height - frame.height, viewStart.y + deltaY))
      frame = nextFrame
    default:
      break
    }
  }
}

final class InAppDebuggerOverlayManager {
  static let shared = InAppDebuggerOverlayManager()

  private var debugWindow: PassThroughWindow?
  private weak var presentedPanelController: UIViewController?
  private let rootViewController = UIViewController()
  private var floatingButton: InAppDebuggerFloatingButtonView?
  private var visible = false
  private var isRestoringFloatingButtonDuringDismissal = false
  private var observers: [NSObjectProtocol] = []

  private init() {
    rootViewController.view.backgroundColor = .clear
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.refreshForCurrentScene()
      }
    )
  }

  func apply(config: DebugConfig) {
    InAppDebuggerStore.shared.update(config: config)
    performOnMain {
      if !config.enabled {
        self.visible = false
        self.hide()
        return
      }
      if self.visible || config.initialVisible {
        self.show()
      }
    }
  }

  func show() {
    performOnMain {
      self.visible = true
      self.refreshForCurrentScene()
    }
  }

  func hide() {
    performOnMain {
      self.visible = false
      self.isRestoringFloatingButtonDuringDismissal = false
      self.presentedPanelController?.dismiss(animated: false)
      self.presentedPanelController = nil
      self.floatingButton?.removeFromSuperview()
      self.floatingButton = nil
      self.debugWindow?.isHidden = true
    }
  }

  func shutdown() {
    performOnMain {
      self.visible = false
      self.isRestoringFloatingButtonDuringDismissal = false
      self.presentedPanelController?.dismiss(animated: false)
      self.presentedPanelController = nil
      self.floatingButton?.removeFromSuperview()
      self.floatingButton = nil
      self.debugWindow?.isHidden = true
      self.debugWindow?.rootViewController = nil
      self.debugWindow = nil
    }
  }

  func presentPanel() {
    performOnMain {
      guard self.visible, self.presentedPanelController == nil else {
        return
      }
      self.refreshForCurrentScene()
      guard let presenter = self.topPresentingViewController() else {
        return
      }
      let panel = InAppDebuggerPanelViewController()
      let nav = UINavigationController(rootViewController: panel)
      nav.modalPresentationStyle = .fullScreen
      self.ensureFloatingButton()
      let floatingButton = self.floatingButton
      floatingButton?.isHidden = false
      floatingButton?.alpha = 1
      floatingButton?.isUserInteractionEnabled = false
      self.presentedPanelController = nav
      // Present from the app's real view-controller stack instead of the overlay window.
      // System text selection menus depend on the normal app window/responder environment.
      presenter.present(nav, animated: true)
      guard let transitionCoordinator = nav.transitionCoordinator ?? presenter.transitionCoordinator else {
        self.applyOverlayState()
        return
      }
      transitionCoordinator.animate(alongsideTransition: { _ in
        floatingButton?.alpha = 0
      }, completion: { context in
        floatingButton?.alpha = 1
        if context.isCancelled {
          self.presentedPanelController = nil
        }
        self.applyOverlayState()
      })
    }
  }

  func panelWillDismiss(using transitionCoordinator: UIViewControllerTransitionCoordinator?) {
    performOnMain {
      guard self.visible, InAppDebuggerStore.shared.currentConfig().enabled, self.presentedPanelController != nil else {
        return
      }
      self.isRestoringFloatingButtonDuringDismissal = true
      self.refreshForCurrentScene()
      self.floatingButton?.alpha = 0
      self.floatingButton?.isUserInteractionEnabled = false
      guard let transitionCoordinator else {
        self.floatingButton?.alpha = 1
        return
      }
      transitionCoordinator.animate(alongsideTransition: { _ in
        self.floatingButton?.alpha = 1
      }, completion: { context in
        if context.isCancelled {
          self.isRestoringFloatingButtonDuringDismissal = false
          self.applyOverlayState()
          return
        }
        self.floatingButton?.alpha = 1
      })
    }
  }

  func panelDidDismiss() {
    performOnMain {
      self.presentedPanelController = nil
      self.isRestoringFloatingButtonDuringDismissal = false
      guard self.visible, InAppDebuggerStore.shared.currentConfig().enabled else {
        self.debugWindow?.isHidden = true
        return
      }
      self.refreshForCurrentScene()
    }
  }

  private func refreshForCurrentScene() {
    guard let scene = activeWindowScene(), InAppDebuggerStore.shared.currentConfig().enabled else {
      debugWindow?.isHidden = true
      return
    }
    if debugWindow?.windowScene !== scene {
      debugWindow?.isHidden = true
      let window = PassThroughWindow(windowScene: scene)
      window.frame = scene.coordinateSpace.bounds
      window.windowLevel = .statusBar + 1
      window.backgroundColor = .clear
      window.rootViewController = rootViewController
      rootViewController.view.frame = window.bounds
      rootViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      debugWindow = window
    }
    debugWindow?.frame = scene.coordinateSpace.bounds
    rootViewController.view.frame = debugWindow?.bounds ?? scene.coordinateSpace.bounds
    applyOverlayState()
  }

  private func ensureFloatingButton() {
    guard let container = rootViewController.view else {
      return
    }
    if let floatingButton, floatingButton.superview === container {
      updateFloatingButtonFrameIfNeeded()
      return
    }
    floatingButton?.removeFromSuperview()
    let bounds = container.bounds.isEmpty ? UIScreen.main.bounds : container.bounds
    let button = InAppDebuggerFloatingButtonView(frame: clampedFloatingButtonFrame(in: bounds))
    button.onTap = { [weak self] in
      self?.presentPanel()
    }
    container.addSubview(button)
    floatingButton = button
  }

  private func applyOverlayState() {
    let shouldKeepWindowVisible = visible && InAppDebuggerStore.shared.currentConfig().enabled
    guard shouldKeepWindowVisible else {
      floatingButton?.isHidden = true
      floatingButton?.alpha = 1
      floatingButton?.isUserInteractionEnabled = false
      debugWindow?.isHidden = true
      return
    }

    debugWindow?.isHidden = false
    ensureFloatingButton()

    let shouldShowFloatingButton = presentedPanelController == nil || isRestoringFloatingButtonDuringDismissal
    floatingButton?.isHidden = !shouldShowFloatingButton
    floatingButton?.alpha = 1
    floatingButton?.isUserInteractionEnabled = shouldShowFloatingButton && presentedPanelController == nil
    if shouldShowFloatingButton {
      updateFloatingButtonFrameIfNeeded()
    }
  }

  private func updateFloatingButtonFrameIfNeeded() {
    guard let container = rootViewController.view, let floatingButton else {
      return
    }
    let bounds = container.bounds.isEmpty ? UIScreen.main.bounds : container.bounds
    floatingButton.frame = clampedFloatingButtonFrame(in: bounds, currentFrame: floatingButton.frame)
  }

  private func clampedFloatingButtonFrame(in bounds: CGRect, currentFrame: CGRect? = nil) -> CGRect {
    let size = CGSize(width: 60, height: 60)
    let minimumX: CGFloat = 20
    let maximumX = max(minimumX, bounds.width - size.width - 20)
    let minimumY = max(bounds.minY + 80, 80)
    let maximumY = max(minimumY, bounds.height - size.height - 32)

    let proposedOrigin = currentFrame?.origin ?? CGPoint(x: maximumX, y: 120)
    return CGRect(
      x: min(max(proposedOrigin.x, minimumX), maximumX),
      y: min(max(proposedOrigin.y, minimumY), maximumY),
      width: size.width,
      height: size.height
    )
  }

  private func activeWindowScene() -> UIWindowScene? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })
  }

  private func topPresentingViewController() -> UIViewController? {
    guard let scene = activeWindowScene() else {
      return nil
    }
    let appWindows = scene.windows.filter { window in
      window !== debugWindow &&
      !window.isHidden &&
      window.alpha > 0.01 &&
      window.rootViewController != nil
    }

    let preferredWindow = appWindows.first(where: { $0.isKeyWindow })
      ?? appWindows.sorted(by: { $0.windowLevel.rawValue > $1.windowLevel.rawValue }).first

    return topViewController(from: preferredWindow?.rootViewController)
  }

  private func topViewController(from controller: UIViewController?) -> UIViewController? {
    if let navigationController = controller as? UINavigationController {
      return topViewController(from: navigationController.visibleViewController)
    }
    if let tabBarController = controller as? UITabBarController {
      return topViewController(from: tabBarController.selectedViewController)
    }
    if let splitViewController = controller as? UISplitViewController,
       let lastController = splitViewController.viewControllers.last {
      return topViewController(from: lastController)
    }
    if let presentedController = controller?.presentedViewController {
      return topViewController(from: presentedController)
    }
    return controller
  }

  private func performOnMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
      return
    }
    DispatchQueue.main.async(execute: work)
  }
}

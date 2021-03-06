/**
 * Copyright © 2019 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import WinSDK
import SwiftCOM
import Foundation

private let pApplicationWindowProc: HOOKPROC = { (nCode: Int32, wParam: WPARAM, lParam: LPARAM) -> LRESULT in
  guard nCode == HC_ACTION else {
    return CallNextHookEx(nil, nCode, wParam, lParam)
  }

  if let pMessage = UnsafeMutablePointer<CWPSTRUCT>(bitPattern: UInt(lParam)) {
    switch pMessage.pointee.message {
    case UINT(WM_ACTIVATEAPP):
      let application: Application = Application.shared
      let bActivation: Bool = pMessage.pointee.wParam > 0
      if bActivation {
        // quiesce foreground notifications
        if application.state == .active { break }
        application.delegate?.applicationWillEnterForeground(application)
        application.state = .active
        application.delegate?.applicationDidBecomeActive(application)
      } else {
        // quiesce background notifications
        if application.state == .background { break }
        application.delegate?.applicationWillResignActive(application)
        Application.shared.state = .background
        application.delegate?.applicationDidEnterBackground(application)
      }
    default:
      break
    }
  }

  return CallNextHookEx(nil, nCode, wParam, lParam)
}

private let pApplicationStateChangeRoutine: PAPPSTATE_CHANGE_ROUTINE = { (quiesced: UInt8, context: PVOID?) in
  guard let delegate = Application.shared.delegate else { return }

  let foregrounding: Bool = quiesced == 0
  if foregrounding {
    NotificationCenter.default
        .post(name: type(of: delegate).willEnterForegroundNotification,
              object: Application.shared)

    delegate.applicationWillEnterForeground(Application.shared)
  } else {
    NotificationCenter.default
        .post(name: type(of: delegate).didEnterBackgroundNotification,
              object: Application.shared)

    delegate.applicationDidEnterBackground(Application.shared)
  }
}

// Waits for a message on the message queue, returning when either a message has
// arrived or the timeout specified has expired.
private func WaitMessage(_ dwMilliseconds: UINT) -> Bool {
  let uIDEvent = WinSDK.SetTimer(nil, 0, dwMilliseconds, nil)
  defer { WinSDK.KillTimer(nil, uIDEvent) }
  return WinSDK.WaitMessage()
}

@discardableResult
public func ApplicationMain(_ argc: Int32,
                            _ argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>,
                            _ application: String?,
                            _ delegate: String?) -> Int32 {
  let hRichEdit: HMODULE? = LoadLibraryW("msftedit.dll".LPCWSTR)
  if hRichEdit == nil {
    log.error("unable to load `msftedit.dll`: \(Error(win32: GetLastError()))")
  }

  if let application = application {
    guard let instance = NSClassFromString(application) else {
      fatalError("unable to find application class: \(application)")
    }
    Application.shared = (instance as! Application.Type).init()
  }
  if let delegate = delegate {
    guard let instance = NSClassFromString(delegate) else {
      fatalError("unable to find delegate class: \(delegate)")
    }
    if instance as? Application.Type == nil {
      Application.shared.delegate = (instance as! ApplicationDelegate.Type).init()
    } else {
      Application.shared.delegate = Application.shared as? ApplicationDelegate
    }
  }

  if let path = Bundle.main.path(forResource: "Info", ofType: "plist") {
      if let contents = FileManager.default.contents(atPath: path) {
        Application.shared.information =
            try? PropertyListDecoder().decode(Application.Information.self,
                                              from: contents)
      }
  }

  // Initialize COM
  do {
    try CoInitializeEx(COINIT_MULTITHREADED)
  } catch {
    log.error("CoInitializeEx: \(error)")
    return EXIT_FAILURE
  }

  // Enable Per Monitor DPI Awareness
  if !SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) {
    log.error("SetProcessDpiAwarenessContext: \(Error(win32: GetLastError()))")
  }

  let dwICC: DWORD = DWORD(ICC_BAR_CLASSES)
                   | DWORD(ICC_DATE_CLASSES)
                   | DWORD(ICC_LISTVIEW_CLASSES)
                   | DWORD(ICC_NATIVEFNTCTL_CLASS)
                   | DWORD(ICC_PROGRESS_CLASS)
                   | DWORD(ICC_STANDARD_CLASSES)
  var ICCE: INITCOMMONCONTROLSEX =
      INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size),
                           dwICC: dwICC)
  InitCommonControlsEx(&ICCE)

  var pAppRegistration: PAPPSTATE_REGISTRATION?
  let ulStatus =
      RegisterAppStateChangeNotification(pApplicationStateChangeRoutine, nil,
                                         &pAppRegistration)
  if ulStatus != ERROR_SUCCESS {
    log.error("RegisterAppStateChangeNotification: \(Error(win32: GetLastError()))")
  }
  defer { UnregisterAppStateChangeNotification(pAppRegistration) }

  var hSwiftWin32: HMODULE?
  let dwFlags: DWORD = DWORD(GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT)
                     | DWORD(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS)
  if !GetModuleHandleExW(dwFlags, #dsohandle.assumingMemoryBound(to: WCHAR.self),
                         &hSwiftWin32) {
    log.error("GetModuleHandleExW: \(Error(win32: GetLastError()))")
  }

  // TODO(compnerd) remove the application window proc hook, we now have scenes
  // and the Window can report the event via the scene.
  let hWindowProcedureHook: HHOOK? =
      SetWindowsHookExW(WH_CALLWNDPROC, pApplicationWindowProc, hSwiftWin32,
                        GetCurrentThreadId())
  if hWindowProcedureHook == nil {
    log.error("SetWindowsHookExW(WH_CALLWNDPROC): \(Error(win32: GetLastError()))")
  }

  defer {
    if let hWindowProcedureHook = hWindowProcedureHook {
      if !UnhookWindowsHookEx(hWindowProcedureHook) {
        log.error("UnhookWindowsHookEx(WndProc): \(Error(win32: GetLastError()))")
      }
    }
  }

  if Application.shared.delegate?
        .application(Application.shared,
                     didFinishLaunchingWithOptions: nil) == false {
    return EXIT_FAILURE
  }

  Application.shared.delegate?
      .applicationDidBecomeActive(Application.shared)

  // TODO(compnerd) populate these based on the application instantiation
  let options: Scene.ConnectionOptions = Scene.ConnectionOptions()

  // Setup the scene session.
  let (_, session) =
      Application.shared.openSessions
          .insert(SceneSession(identifier: UUID().uuidString,
                               role: .windowApplication))

  // Update the scene configuration based on the delegate's response.
  if let configuration = Application.shared.delegate?
      .application(Application.shared, configurationForConnecting: session,
                   options: options) {
    session.configuration = configuration
  }

  // Create the scene.
  let SceneType =
      (session.configuration.sceneClass as? Scene.Type) ?? WindowScene.self

  let (_, scene) =
      Application.shared.connectedScenes
          .insert(SceneType.init(session: session, connectionOptions: options))

  if let DelegateType =
      session.configuration.delegateClass as? SceneDelegate.Type {
    // Only instantiate the scene delegate if the scene delegate is not the
    // Application class or the ApplicationDelegate class.
    if DelegateType as? Application.Type == nil {
      if DelegateType as? ApplicationDelegate.Type == nil {
        scene.delegate = DelegateType.init()
      } else {
        scene.delegate = Application.shared.delegate as? SceneDelegate
      }
    } else {
      scene.delegate = Application.shared as? SceneDelegate
    }
  }

  scene.delegate?.scene(scene, willConnectTo: session, options: options)
  session.scene = scene

  var msg: MSG = MSG()
  var nExitCode: Int32 = EXIT_SUCCESS

  mainLoop: while true {
    // Process all messages in thread's message queue; for GUI applications UI
    // events must have high priority.
    while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
      if msg.message == UINT(WM_QUIT) {
        nExitCode = Int32(msg.wParam)
        break mainLoop
      }

      TranslateMessage(&msg)
      DispatchMessageW(&msg)
    }

    var limitDate: Date? = nil
    repeat {
      // Execute Foundation.RunLoop once and determine the next time the timer
      // fires.  At this point handle all Foundation.RunLoop timers, sources and
      // Dispatch.DispatchQueue.main tasks
      limitDate = RunLoop.main.limitDate(forMode: .default)

      // If Foundation.RunLoop doesn't contain any timers or the timers should
      // not be running right now, we interrupt the current loop or otherwise
      // continue to the next iteration.
    } while (limitDate?.timeIntervalSinceNow ?? -1) <= 0

    // Yield control to other threads.  If Foundation.RunLoop contains a timer
    // to execute, we wait until a new message is placed in the thread's message
    // queue or the timer must fire, otherwise we proceed to the next iteration
    // of mainLoop, using 0 as the wait timeout.
    _ = WaitMessage(DWORD(exactly: limitDate?.timeIntervalSinceNow ?? 0 * 1000)
                        ?? DWORD.max)
  }

  Application.shared.delegate?.applicationWillTerminate(Application.shared)

  return nExitCode
}

extension ApplicationDelegate {
  public static func main() {
    ApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                    String(describing: String(reflecting: Self.self)))
  }
}

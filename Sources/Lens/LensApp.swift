import AppKit
import SwiftUI

@main
struct LensApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Lens") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 780)
        .commands {
            // 相机应用没有「新建文档」的概念，去掉它。
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 虚拟背景自检：跑完即退出，不进主界面。
        if let input = DebugSupport.backgroundTestInput,
           let output = DebugSupport.backgroundTestOutput {
            DebugSupport.runBackgroundTest(input: input, output: output)
            return
        }

        if let path = DebugSupport.snapshotPath {
            DebugSupport.captureMainWindow(to: path)
        }

        if let delay = DebugSupport.autoCloseDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSLog("[Lens] 自检：关闭主窗口")
                NSApp.windows.first(where: { $0.isVisible })?.performClose(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

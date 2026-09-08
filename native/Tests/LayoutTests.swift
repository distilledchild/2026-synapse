import SwiftUI
import AppKit

@main
struct LayoutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            checks += 1; print("PASS: \(label)")
        }
        for width: CGFloat in [540, 800, 1100] {
            func bar(refreshing: Bool, count: Int = 2543, unavailable: Int = 0, live: Bool = true, demo: Bool = false, date: Date? = Date(timeIntervalSince1970: 1788883200)) -> some View {
                InboxStatusBar(isDemo: demo, isLiveConnection: live, hasError: false,
                    messageCount: count, unavailableCount: unavailable,
                    isRefreshing: refreshing, lastUpdated: date).frame(width: width)
            }
            let host = NSHostingView(rootView: bar(refreshing: false))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 100)
            var heights: [CGFloat] = []
            for iteration in 0..<40 {
                host.rootView = bar(refreshing: iteration.isMultiple(of: 2))
                host.layoutSubtreeIfNeeded()
                heights.append(host.fittingSize.height)
            }
            check(Set(heights).count == 1, "status bar height stays constant across 40 refresh transitions at width \(Int(width))")
            check(heights.first == 40, "spinner space is reserved even while idle at width \(Int(width))")
            host.rootView = bar(refreshing: true, count: 123456, unavailable: 321)
            host.layoutSubtreeIfNeeded()
            check(host.fittingSize.height == 40, "long counters cannot wrap and push the composer at width \(Int(width))")
            host.rootView = bar(refreshing: false, count: 8, live: false, demo: true, date: nil)
            host.layoutSubtreeIfNeeded()
            check(host.fittingSize.height == 40, "sample status without a timestamp keeps the same height at width \(Int(width))")
            host.rootView = bar(refreshing: false, live: false)
            host.layoutSubtreeIfNeeded()
            check(host.fittingSize.height == 40, "imported database status keeps the same height at width \(Int(width))")
        }
        print("SUCCESS: \(checks) layout checks using the production SwiftUI status bar")
    }
}

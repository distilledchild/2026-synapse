import SwiftUI

struct InboxStatusBar: View {
    let isDemo: Bool
    let isLiveConnection: Bool
    let hasError: Bool
    let messageCount: Int
    let unavailableCount: Int
    let isRefreshing: Bool
    let lastUpdated: Date?

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(hasError ? Color.orange : isDemo ? Color.gray : Color.green).frame(width: 6, height: 6)
            Text(isDemo ? "\(messageCount) sample messages" : "\(messageCount) messages loaded")
            if unavailableCount > 0 { Text("\(unavailableCount) unsupported messages").foregroundStyle(.orange) }
            Spacer()
            // A conditional spinner directly in the row changed its height from
            // 13 to 16 points, pushing the composer up and down on every refresh.
            ZStack {
                if isRefreshing {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing messages")
                }
            }.frame(width: 16, height: 16)
            if let date = lastUpdated { Text(date, style: .time).monospacedDigit() }
            Text(isLiveConnection ? "Messages & photos · Local alpha" : isDemo ? "Sample · Local alpha" : "Imported database · Read-only")
                .foregroundStyle(.secondary).layoutPriority(-1)
        }.font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(12)
    }
}

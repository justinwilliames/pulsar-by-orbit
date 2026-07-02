import SwiftUI

struct HistoryPanelView: View {
    let viewModel: DashboardViewModel

    @State private var expandedId: String?
    @State private var playingKey: String?

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.historyEntries.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Nothing spoken yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Every line Pulsar speaks appears here.\nCached lines replay for free.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.historyEntries) { entry in
                            historyRow(entry)
                            Divider().padding(.leading, 12)
                        }

                        Button("Load more") {
                            Task { await viewModel.loadMoreHistory() }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(8)
                    }
                }
            }

            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .task {
            async let _ = viewModel.loadCachedPhrases()
        }
    }

    // MARK: - Row

    private func historyRow(_ entry: HistoryEntry) -> some View {
        let cached = viewModel.cachedTextIndex[entry.text]
        let isReplaying = playingKey == cached?.key

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(expandedId == entry.id ? nil : 2)

                HStack(spacing: 6) {
                    if let cached {
                        Label("\(cached.playCount)", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        // Cache hit badge
                        Text("cached · free")
                            .font(.caption2)
                            .foregroundStyle(.green.opacity(0.8))

                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(formatBytes(cached.sizeBytes))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(relativeTime(entry.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if entry.failed {
                        Text("· failed")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.7))
                    }
                }
            }

            Spacer()

            if let cached {
                Button {
                    playingKey = cached.key
                    Task {
                        await viewModel.playCachedPhrase(key: cached.key)
                        try? await Task.sleep(for: .milliseconds(600))
                        if playingKey == cached.key { playingKey = nil }
                    }
                } label: {
                    Image(systemName: isReplaying ? "speaker.wave.2.fill" : "play.circle.fill")
                        .font(.caption)
                        .symbolEffect(.pulse, isActive: isReplaying)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Replay — free from cache")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedId = expandedId == entry.id ? nil : entry.id
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            let cachedCount = viewModel.cachedPhrases.count
            if cachedCount > 0 {
                Image(systemName: "tray.full")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(cachedCount) cached · \(formatBytes(viewModel.cacheTotalBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if viewModel.cacheMaxBytes > 0 {
                    Text("/ \(formatBytes(viewModel.cacheMaxBytes))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No cached phrases yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("Replays free")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

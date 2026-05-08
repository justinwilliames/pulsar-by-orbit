import SwiftUI

struct CachePanelView: View {
    let viewModel: DashboardViewModel

    @State private var hasLoaded = false
    @State private var playingKey: String?

    var body: some View {
        VStack(spacing: 0) {
            sortChips
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if viewModel.cachedPhrases.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No cached phrases yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Caldwell caches each new phrase the first time it's spoken.\nReplays from this list cost zero credits.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.cachedPhrases) { phrase in
                            phraseRow(phrase)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }

            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .task(id: hasLoaded) {
            if !hasLoaded {
                await viewModel.loadCachedPhrases()
                hasLoaded = true
            }
        }
        .onAppear {
            Task { await viewModel.loadCachedPhrases() }
        }
    }

    private var sortChips: some View {
        HStack(spacing: 6) {
            sortChip("Recent", sort: .recent)
            sortChip("Popular", sort: .popular)
            Spacer()
            Button {
                Task { await viewModel.loadCachedPhrases() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
    }

    private func sortChip(_ label: String, sort: DaemonAPI.CacheSort) -> some View {
        let isActive = viewModel.cacheSort == sort
        return Button {
            Task { await viewModel.setCacheSort(sort) }
        } label: {
            Text(label)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(
                    isActive ? .regular.tint(.accentColor) : .regular,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func phraseRow(_ phrase: CachedPhrase) -> some View {
        let displayText = phrase.isLegacy ? "(legacy phrase — text unknown)" : phrase.text
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(.caption)
                    .foregroundStyle(phrase.isLegacy ? .tertiary : .primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label("\(phrase.playCount)", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let lastPlayed = phrase.lastPlayedDate {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(relativeTime(lastPlayed))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(formatBytes(phrase.sizeBytes))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                playingKey = phrase.key
                Task {
                    await viewModel.playCachedPhrase(key: phrase.key)
                    try? await Task.sleep(for: .milliseconds(600))
                    if playingKey == phrase.key { playingKey = nil }
                }
            } label: {
                Image(systemName: playingKey == phrase.key ? "speaker.wave.2.fill" : "play.circle")
                    .font(.caption)
                    .symbolEffect(.pulse, isActive: playingKey == phrase.key)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive())
            .help("Replay (free — from cache)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.cachedPhrases.count) phrase\(viewModel.cachedPhrases.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(formatBytes(viewModel.cacheTotalBytes))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if viewModel.cacheMaxBytes > 0 {
                Text("/ \(formatBytes(viewModel.cacheMaxBytes))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("Replays free")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

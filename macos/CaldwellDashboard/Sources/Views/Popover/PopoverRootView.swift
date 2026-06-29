import AppKit
import Sparkle
import SwiftUI

enum DashboardTab: String, CaseIterable {
    case history = "History"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .history: "clock"
        case .settings: "gear"
        }
    }

    var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - Carousel Transition

struct CarouselTransition: Transition {
    let forward: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let sign: CGFloat = switch phase {
        case .willAppear: forward ? 1 : -1
        case .didDisappear: forward ? -1 : 1
        case .identity: 0
        }
        let progress: CGFloat = phase == .identity ? 0 : 1

        content
            .offset(x: progress * sign * 360)
            .scaleEffect(1 - progress * 0.18)
            .rotation3DEffect(
                .degrees(Double(-sign * 18) * progress),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.4
            )
            .opacity(1 - progress)
    }
}

// MARK: - Root View

struct PopoverRootView: View {
    let viewModel: DashboardViewModel
    let updater: SPUUpdater

    @State private var selectedTab: DashboardTab = .history
    @State private var navigatingForward = true

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            tabContent
        }
        .frame(width: 360, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Pulsar")
                .font(.headline)

            Spacer()

            muteToggle

            ConnectionStatusView(status: viewModel.connectionStatus)

            quitButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .task {
            // Refresh settings every time the popover opens so the mute state —
            // and the toggle bound to it — always reflects the daemon's truth,
            // never a value that drifted while the popover was closed. Loading
            // unconditionally is what lets a stale toggle self-correct.
            await viewModel.loadSettings()
        }
    }

    private var muteToggle: some View {
        let muted = viewModel.isMuted
        return Button {
            Task { await viewModel.toggleMute() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption.weight(.semibold))
                Text(muted ? "Muted" : "Live")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(muted ? Color.red.opacity(0.18) : Color.green.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(muted ? Color.red.opacity(0.4) : Color.green.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(muted ? "Pulsar is muted — click to unmute." : "Click to mute Pulsar.")
    }

    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
                .background(Color.secondary.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Quit Pulsar")
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    guard tab != selectedTab else { return }
                    navigatingForward = tab.index > selectedTab.index
                    withAnimation(.spring(duration: 0.5, bounce: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .symbolEffect(.bounce, value: isSelected)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                .help(tab.rawValue)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            tabView(for: selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selectedTab)
                .transition(CarouselTransition(forward: navigatingForward))
        }
        .clipped()
        .animation(.spring(duration: 0.55, bounce: 0.15), value: selectedTab)
    }

    @ViewBuilder
    private func tabView(for tab: DashboardTab) -> some View {
        switch tab {
        case .history:
            HistoryPanelView(viewModel: viewModel)
        case .settings:
            SettingsView(viewModel: viewModel, updater: updater)
        }
    }
}

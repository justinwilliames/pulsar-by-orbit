import SwiftUI

enum DashboardTab: String, CaseIterable {
    case history = "History"
    case cache = "Cache"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .history: "clock"
        case .cache: "tray.full"
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

    @State private var selectedTab: DashboardTab = .history
    @State private var navigatingForward = true
    @Namespace private var tabNamespace

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                header
                tabPicker
                tabContent
            }
            .frame(width: 360, height: 520)
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Caldwell")
                .font(.headline)

            Spacer()

            muteToggle

            ConnectionStatusView(status: viewModel.connectionStatus)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .task {
            // Pull settings on first popover load so the mute state is accurate
            if viewModel.settings == nil {
                await viewModel.loadSettings()
            }
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
            .glassEffect(
                muted ? .regular.tint(.red).interactive() : .regular.tint(.green).interactive(),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(muted ? "Caldwell is muted — click to unmute. No ElevenLabs calls while muted." : "Click to mute Caldwell — stops all ElevenLabs calls until unmuted.")
    }

    private var tabPicker: some View {
        GlassEffectContainer(spacing: 0) {
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
                    .glassEffect(
                        isSelected ? .regular.tint(.accentColor).interactive() : .clear,
                        in: Capsule()
                    )
                    .glassEffectID(tab.rawValue, in: tabNamespace)
                    .help(tab.rawValue)
                }
            }
        }
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
        case .cache:
            CachePanelView(viewModel: viewModel)
        case .settings:
            SettingsView(viewModel: viewModel)
        }
    }
}

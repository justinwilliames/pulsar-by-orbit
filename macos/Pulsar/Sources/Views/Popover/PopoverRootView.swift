import AppKit
import os
import Sparkle
import SwiftUI

private let logger = Logger(subsystem: "team.yourorbit.Pulsar", category: "PopoverRootView")

enum DashboardTab: String, CaseIterable {
    case roster = "Team"
    case missions = "Missions"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .roster: "person.3"
        case .missions: "list.bullet.rectangle"
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

    // Default to the Team/Roster tab on first open (history is empty then) so
    // new users immediately see the drone roster rather than an empty clock panel.
    // Once history has entries the user has already discovered the app.
    @State private var selectedTab: DashboardTab = .roster
    @State private var navigatingForward = true

    // Tabs visible in the picker. Missions is hidden unless Task Mode is on.
    private var visibleTabs: [DashboardTab] {
        DashboardTab.allCases.filter { $0 != .missions || viewModel.isTaskModeEnabled }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            tabContent
            orbitFooter
        }
        .frame(width: 360, height: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .onChange(of: viewModel.isTaskModeEnabled) { _, enabled in
            // If Task Mode is switched off while its tab is selected, fall back
            // to the roster so we never render a now-hidden tab.
            if !enabled, selectedTab == .missions {
                selectedTab = .roster
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // Small Orbit-indigo squircle hosting the white waveform.path glyph —
            // mirrors how Comet renders CometMark, gives the popover a clear
            // brand anchor before the title.
            PulsarMark(size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pulsar")
                    .font(.title3.weight(.semibold))
                Text("Your AI tells you when it's done — stop watching the screen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    // "by Orbit AI · yourorbit.team" — the Orbit company mark + link, marking
    // Pulsar as an Orbit product. Mirrors Comet's orbitFooter placement.
    private var orbitFooter: some View {
        HStack(spacing: 5) {
            Group {
                if let nsImage = NSImage(named: "OrbitLogo") {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.orbit)
                }
            }
            .frame(width: 12, height: 12)
            .foregroundStyle(.secondary)
            Text("by Orbit AI")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Link("yourorbit.team", destination: URL(string: "https://yourorbit.team")!)
            Spacer()
            Button("About") {
                openAbout()
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func openAbout() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            logger.error("openAbout: could not cast NSApp.delegate to AppDelegate")
            return
        }
        appDelegate.showAbout()
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
        HStack(spacing: 4) {
            ForEach(visibleTabs, id: \.self) { tab in
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
                .background(isSelected ? Color.orbit.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help(tab.rawValue)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        case .roster:
            RosterView()
        case .missions:
            MissionsView(viewModel: viewModel)
        case .settings:
            SettingsView(viewModel: viewModel, updater: updater)
        }
    }
}

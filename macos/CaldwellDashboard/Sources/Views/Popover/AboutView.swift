import AppKit
import SwiftUI

struct AboutView: View {
    private let repositoryURL = URL(string: "https://github.com/justinwilliames/pulsar-by-orbit")!
    private let upstreamURL = URL(string: "https://github.com/tomc98/speak")!
    private let orbitURL = URL(string: "https://yourorbit.team")!

    var body: some View {
        VStack(spacing: 18) {
            PulsarMark(size: 72)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 6)

            VStack(spacing: 6) {
                Text("Pulsar")
                    .font(.title2.weight(.semibold))

                Text("by Orbit AI")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("Menu-bar voice narrator for macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Text("Pulsar speaks text aloud — powered by local macOS voices, driven by Claude Code hooks. Speaks bespoke lines as Caldwell, end of every turn.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Link(destination: repositoryURL) {
                    Label("GitHub Repository", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orbit)

                HStack(spacing: 6) {
                    orbitLogoImage
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.secondary)
                    Link("yourorbit.team", destination: orbitURL)
                        .font(.callout)
                }

                HStack(spacing: 4) {
                    Text("Forked from")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("speak", destination: upstreamURL)
                        .font(.caption)
                }
            }

            Divider()

            Text(copyrightLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 360)
    }

    /// OrbitLogo loaded from Bundle.main (copied to Contents/Resources/ by the
    /// build script). Falls back gracefully to an SF Symbol if the PNG is absent.
    @ViewBuilder
    private var orbitLogoImage: some View {
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

    private var versionLabel: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let build, build != version {
            return "Version \(version) (\(build))"
        }

        return "Version \(version)"
    }

    private var copyrightLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Justin Williames. Forked from speak (MIT)."
    }
}

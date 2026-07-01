import AppKit
import SwiftUI

/// "Meet the team" — the full cast of Pulsar + his sub-agent drones. Each entry
/// shows the character's portrait (its `<name>-mouth-0` frame), NAME · ROLE, its
/// signature colour, and a one-line description of what it does. Names, roles,
/// and colours come from `DroneRegistry`; Pulsar (the Orchestrator) is prepended
/// since he isn't a drone in the registry.
struct RosterView: View {
    /// One roster row's data — portrait key, display name, role, colour, blurb.
    private struct CastMember: Identifiable {
        let id: String        // portrait/frame prefix, e.g. "pulsar", "voyager"
        let name: String
        let role: String
        let color: Color
        let blurb: String
    }

    /// Pulsar first (Orchestrator, indigo), then the six drones from the
    /// registry in canonical order. Blurbs describe each character's job.
    private var cast: [CastMember] {
        var out: [CastMember] = [
            CastMember(id: "pulsar", name: "Pulsar", role: "Orchestrator",
                       color: .orbitLight,
                       blurb: "Runs the show — plans the work, delegates to the drones, and narrates the session.")
        ]
        let blurbs: [String: String] = [
            "voyager":  "Scouts the codebase — searches, explores, and reports back what it finds.",
            "sentinel": "Reviews the work — audits, critiques, and catches bugs and security issues.",
            "nova":     "Builds it — implements features, refactors, and gets the code compiling.",
            "nebula":   "Makes it beautiful — design, images, icons, and visual polish.",
            "echo":     "Writes it up — docs, changelogs, copy, and clear prose.",
            "atlas":    "The all-rounder — picks up whatever general task needs doing.",
        ]
        for drone in DroneRegistry.drones {
            out.append(CastMember(
                id: drone.category,
                name: drone.category.capitalized,
                role: drone.role.capitalized,
                color: drone.color,
                blurb: blurbs[drone.category] ?? ""))
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("MEET THE TEAM")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .padding(.horizontal, 4)

                ForEach(cast) { member in
                    row(member)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func row(_ member: CastMember) -> some View {
        HStack(alignment: .top, spacing: 12) {
            portrait(member)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(member.name.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.primary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(member.role.uppercased())
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(member.color)
                }
                Text(member.blurb)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(member.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(member.color.opacity(0.25), lineWidth: 1)
                )
        )
    }

    /// The character's portrait, clipped to the same squircle the floating head
    /// uses, with its signature colour glow. Falls back to a coloured monogram if
    /// the frame image is missing.
    @ViewBuilder
    private func portrait(_ member: CastMember) -> some View {
        let size: CGFloat = 46
        let squircle = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        Group {
            if let img = NSImage(named: "\(member.id)-mouth-0") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                squircle
                    .fill(member.color.opacity(0.3))
                    .overlay(
                        Text(String(member.name.prefix(1)))
                            .font(.system(size: size * 0.4, weight: .bold))
                            .foregroundStyle(member.color)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(squircle)
        .overlay(squircle.strokeBorder(member.color.opacity(0.6), lineWidth: 1.5))
        .shadow(color: member.color.opacity(0.5), radius: 6)
    }
}

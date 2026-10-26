import SwiftUI
import UIKit

// Batch S3, watch party UI. Not compiled: the owner's CI builds it.

/// Settings → Watch party, and the sheet from a title page. Start a party or join one. In a party: the code, who is in it,
/// the host's switches, and (from a title page) a suggestion to the room.
struct PartyView: View {
    /// The title on the page this came from, if any. A guest in a party can suggest it.
    var suggest: MetaPreview? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileStore.self) private var profiles
    @State private var code = ""
    @State private var name = ""
    /// A join was asked for: when the room welcomes this device, the party player opens.
    @State private var joining = false
    @State private var suggestSending = false
    @State private var suggestSent = false

    private var party: PartySession { PartySession.shared }

    var body: some View {
        Form {
            if party.code != nil {
                roomSections
            } else {
                startSection
                joinSection
            }
            if let notice = party.notice {
                Section { Text(notice).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Watch party")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if name.isEmpty { name = profiles.active.name } }
        .onChange(of: party.phase) { _, phase in
            guard joining else { return }
            if phase == .inRoom, !party.isHost {
                joining = false
                PartyRouter.shared.openGuestPlayer()
                dismiss()
            } else if phase != .connecting {
                joining = false
            }
        }
    }

    // MARK: Not in a party

    private var startSection: some View {
        Section {
            TextField("Your name", text: $name)
            Button {
                Task { await party.createRoom(hostName: name) }
            } label: {
                Label("Start a party", systemImage: "person.2.fill")
            }
            .disabled(party.phase != .idle || PartyName.clean(name) == nil)
        } header: {
            Text("Host")
        } footer: {
            Text("You pick what plays. Each guest plays it on their own device with their own add-ons.")
        }
    }

    private var joinSection: some View {
        Section {
            TextField("Party code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            Button {
                joining = true
                Task { await party.join(code: code, name: name) }
            } label: {
                Label("Join", systemImage: "arrow.right.circle")
            }
            .disabled(party.phase != .idle || PartyCode.clean(code) == nil || PartyName.clean(name) == nil)
        } header: {
            Text("Join")
        } footer: {
            Text("Enter the six-letter code from the host.")
        }
    }

    // MARK: In a party

    @ViewBuilder private var roomSections: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Party code").font(.archivo(.footnote)).foregroundStyle(.secondary)
                    Text(party.code ?? "").font(.system(.title2, design: .monospaced).weight(.bold))
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = party.code
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            LabeledContent("Status", value: statusText)
        } footer: {
            Text("Share this code. Your stream is never sent to anyone: each guest finds the same title on their own device.")
        }

        Section("Members") {
            ForEach(party.members) { member in
                HStack {
                    Circle()
                        .fill(member.ready ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 9, height: 9)
                    Text(member.name)
                    Spacer()
                    if member.role == "host" {
                        Text("Host").font(.archivo(.caption)).foregroundStyle(.secondary)
                    } else if !member.connected {
                        Text("Offline").font(.archivo(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }

        if party.isHost {
            Section {
                Toggle("Lock party", isOn: Binding(get: { party.locked }, set: { party.setLocked($0) }))
                Toggle("Approve requests automatically", isOn: Binding(get: { party.autoApprove }, set: { party.setAutoApprove($0) }))
            } footer: {
                Text("A locked party takes no new members. Guests' requests to play or pause are answered in the player.")
            }
        }

        if !party.suggestions.isEmpty {
            Section("Suggestions") {
                ForEach(party.suggestions) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.source.title).font(.archivo(.body, weight: .semibold))
                        Text("From \(memberName(s.from))").font(.archivo(.footnote)).foregroundStyle(.secondary)
                        if let note = s.note { Text(note).font(.archivo(.footnote)) }
                    }
                }
            }
        }

        if let suggest, !party.isHost {
            Section {
                Button {
                    suggestTitle(suggest)
                } label: {
                    Label(suggestSent ? "Suggested to the host" : "Suggest \(suggest.name)", systemImage: "paperplane")
                }
                .disabled(suggestSending || suggestSent)
            }
        }

        Section {
            if !party.isHost {
                Button {
                    PartyRouter.shared.openGuestPlayer()
                    dismiss()
                } label: {
                    Label("Open the party player", systemImage: "play.rectangle")
                }
            }
            Button(role: .destructive) {
                party.leave()
            } label: {
                Label(party.isHost ? "End party" : "Leave party", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }

        if case .ended = party.phase {
            Section {
                Button("Close") { party.dismiss() }
            }
        }
    }

    private var statusText: String {
        switch party.phase {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .inRoom: return party.isHost ? "You are hosting" : "Joined"
        case .ended: return "Ended"
        case .unavailable(let message): return message
        case .idle: return "Not connected"
        }
    }

    private func memberName(_ id: String) -> String {
        party.members.first(where: { $0.id == id })?.name ?? "A guest"
    }

    /// Sends the title on this page to the room, with its IMDb id so every guest can find it.
    private func suggestTitle(_ item: MetaPreview) {
        suggestSending = true
        Task {
            defer { suggestSending = false }
            guard let imdb = await SourceResolver.stremioID(for: item) else { return }
            let source = PartySource(type: item.type == "series" ? "series" : "movie", imdb: imdb,
                                     title: item.name, year: item.year)
            suggestSent = party.suggest(source)
        }
    }
}

/// The party sheet from a title page.
struct PartySheet: View {
    var suggest: MetaPreview? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PartyView(suggest: suggest)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// The party panel inside the player: the code, who is in the party, and for the host the switches, the requests and
/// the suggestions ("Watch this" closes the player and opens that title's page).
struct PartyRoomPanel: View {
    let adapter: PartyHostAdapter?
    let glass: Bool
    let onWatch: (MetaPreview) -> Void
    let onLeave: () -> Void
    let onClose: () -> Void

    @Environment(ThemeStore.self) private var theme

    private var party: PartySession { PartySession.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Watch party").font(.archivo(.title3, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Close party")
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CODE").font(.archivo(.caption, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
                    Text(party.code ?? "").font(.system(.title2, design: .monospaced).weight(.bold))
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = party.code
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.archivo(.footnote, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    membersBlock
                    if party.isHost { hostBlock }
                    if !party.suggestions.isEmpty { suggestionsBlock }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)

            Button(role: .destructive, action: onLeave) {
                Label(party.isHost ? "End party" : "Leave party", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
        .tint(theme.accent)
        .padding(18)
        .frame(width: 340)
        .modifier(PartyPanelGlass(on: glass))
    }

    private var membersBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEMBERS").font(.archivo(.caption, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
            ForEach(party.members) { m in
                HStack(spacing: 10) {
                    Circle().fill(m.ready ? Color.green : Color.white.opacity(0.3)).frame(width: 9, height: 9)
                    Text(m.name).font(.archivo(.body, weight: .medium)).lineLimit(1)
                    Spacer()
                    if m.role == "host" {
                        Text("Host").font(.archivo(.caption)).foregroundStyle(.white.opacity(0.6))
                    } else if !m.connected {
                        Text("Offline").font(.archivo(.caption)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
    }

    @ViewBuilder private var hostBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Lock party", isOn: Binding(get: { party.locked }, set: { party.setLocked($0) }))
            Toggle("Approve requests automatically", isOn: Binding(get: { party.autoApprove }, set: { party.setAutoApprove($0) }))
        }
        if !party.requests.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("REQUESTS").font(.archivo(.caption, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
                ForEach(party.requests) { r in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memberName(r.from)).font(.archivo(.body, weight: .semibold)).lineLimit(1)
                            Text(r.action == "play" ? "Asks to play" : "Asks to pause")
                                .font(.archivo(.footnote)).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Button("Deny") { decide(r, approve: false) }.buttonStyle(.bordered)
                        Button("Approve") { decide(r, approve: true) }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var suggestionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SUGGESTIONS").font(.archivo(.caption, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
            ForEach(party.suggestions) { s in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.source.title).font(.archivo(.body, weight: .semibold)).lineLimit(2)
                        Text("From \(memberName(s.from))").font(.archivo(.footnote)).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    if party.isHost {
                        Button("Watch this") { onWatch(s.source.item) }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func decide(_ request: PartyRequest, approve: Bool) {
        if let adapter {
            adapter.decide(request, approve: approve)
        } else {
            party.resolve(request, approve: approve)
        }
    }

    private func memberName(_ id: String) -> String {
        party.members.first(where: { $0.id == id })?.name ?? "A guest"
    }
}

/// The panel's background: Liquid Glass when the player uses glass, a dark card otherwise (same as the player's panels).
private struct PartyPanelGlass: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.glassEffect(.regular, in: .rect(cornerRadius: 26)) }
        else { content.background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 26, style: .continuous)) }
    }
}

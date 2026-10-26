import SwiftUI
import UIKit

/// Settings → Pear.pair (batch S1, the iOS counterpart of Kotlin's K3). Create or join an account, show a pair code for another
/// device, see and remove devices, sync now, sign out and delete the account. It never shows a token or a URL.
struct PairSettingsView: View {
    private let sync = PairSync.shared

    @State private var busy = false
    @State private var error: String?
    @State private var showJoinSheet = false
    @State private var showRecoverSheet = false
    /// Set by a join sheet when the device has joined. The choice dialog opens when that sheet has closed.
    @State private var joinedNeedsChoice = false
    @State private var askChoice = false
    @State private var recoveryReveal: RecoveryReveal?
    @State private var pairCode: PairCodeInfo?
    @State private var devices: [PairDevice] = []
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    /// The "Sync settings" switch. The same key is read by PairSync.syncSettingsOn.
    @AppStorage("pair.syncSettings") private var syncSettings = false

    private var deviceName: String { UIDevice.current.name }

    var body: some View {
        Form {
            if sync.isSignedIn {
                signedInSections
            } else {
                signedOutSections
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Pear.pair")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .task { await reloadDevices() }
        .onChange(of: syncSettings) { _, on in sync.setSyncSettings(on) }
        .sheet(isPresented: $showJoinSheet, onDismiss: openChoiceIfJoined) {
            JoinWithCodeSheet(joined: $joinedNeedsChoice)
        }
        .sheet(isPresented: $showRecoverSheet, onDismiss: openChoiceIfJoined) {
            RecoverSheet(joined: $joinedNeedsChoice)
        }
        .sheet(item: $recoveryReveal) { reveal in
            RecoveryKeySheet(reveal: reveal)
        }
        .confirmationDialog("Your data on this device", isPresented: $askChoice, titleVisibility: .visible) {
            Button("Merge with this account") { sync.finishSignIn(replaceLocal: false) }
            Button("Replace this device's data", role: .destructive) { sync.finishSignIn(replaceLocal: true) }
            Button("Cancel", role: .cancel) { sync.finishSignIn(replaceLocal: false) }
        } message: {
            Text("Merging keeps what is on this device and in the account, and the newer record wins. Replacing discards this device's history and library and takes the account's. Cancel merges.")
        }
        .confirmationDialog("Sign out of this device?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                run {
                    _ = await sync.signOut()
                    pairCode = nil
                    devices = []
                }
            }
        } message: {
            Text("This device keeps its data. The device is removed from the account.")
        }
        .confirmationDialog("Delete the account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                run {
                    try await sync.deleteAccount()
                    pairCode = nil
                    devices = []
                }
            }
        } message: {
            Text("The account and its synced data are removed from Pear.pair on every device. This device keeps its data.")
        }
    }

    // MARK: Signed out

    @ViewBuilder private var signedOutSections: some View {
        Section {
            Button("Create account") {
                run {
                    let made = try await sync.createAccount(deviceName: deviceName)
                    recoveryReveal = RecoveryReveal(accountID: made.accountID, key: made.recoveryKey)
                }
            }
            Button("Pair this device") { showJoinSheet = true }
            Button("Recover with key") { showRecoverSheet = true }
        } header: {
            Text("Sign in")
        } footer: {
            Text("There is no email or password. An account is a recovery key you keep safe. A new device joins with a short code from a device that is already signed in, or with the recovery key.")
        }
    }

    // MARK: Signed in

    @ViewBuilder private var signedInSections: some View {
        Section {
            LabeledContent("Status", value: statusText)
            if let last = sync.state.lastSyncAt {
                LabeledContent("Last synced") {
                    Text(last, style: .relative)
                }
            }
            Button("Sync now") { sync.syncNow() }
        } header: {
            Text("This device")
        }

        Section {
            Toggle("Sync settings", isOn: $syncSettings)
        } footer: {
            Text("Add-ons, API keys, subtitles, playback and appearance. Add-on addresses and API keys are stored on the Pear.pair server and are not end-to-end encrypted.")
        }

        Section {
            Button("Show pair code for another device") {
                run {
                    let made = try await sync.makePairCode()
                    pairCode = PairCodeInfo(code: made.code, expires: made.expiresAt)
                }
            }
            if let info = pairCode {
                PairCodeView(info: info)
            }
        } footer: {
            Text("Enter this code on the other device within five minutes. It works once.")
        }

        Section {
            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(device.current ? "\(device.platform) · this device" : device.platform)
                            .font(.archivo(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !device.current {
                        Button("Remove", role: .destructive) {
                            run {
                                try await sync.revokeDevice(id: device.id)
                                await reloadDevices()
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Devices")
        }

        Section {
            Button("Sign out of this device") { confirmSignOut = true }
            Button("Delete account", role: .destructive) { confirmDelete = true }
        } footer: {
            Text("Signing out keeps this device's data and removes the device from the account. Deleting the account removes it from every device.")
        }
    }

    // MARK: Helpers

    private var statusText: String {
        if sync.state.syncing { return "Syncing…" }
        if sync.state.pausedUntil != nil { return "Paused" }
        return sync.state.error == nil ? "Up to date" : "Waiting"
    }

    private func openChoiceIfJoined() {
        if joinedNeedsChoice {
            joinedNeedsChoice = false
            askChoice = true
        }
    }

    private func reloadDevices() async {
        guard sync.isSignedIn else {
            devices = []
            return
        }
        if let list = try? await sync.devices() { devices = list }
    }

    /// Runs one account call, shows its failure in plain words, and holds the screen still meanwhile.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Try again."
            }
        }
    }
}

/// The pair code, big enough to read across a room, with a countdown.
private struct PairCodeView: View {
    let info: PairCodeInfo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(info.expires.timeIntervalSince(context.date).rounded(.down))
            VStack(spacing: 8) {
                Text(info.code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Text(left > 0 ? "Expires in \(left / 60):\(String(format: "%02d", left % 60))" : "Expired. Make a new code.")
                    .font(.archivo(.footnote))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The account ID and recovery key, shown once after an account is made.
struct RecoveryReveal: Identifiable {
    let id = UUID()
    let accountID: String
    let key: String
}

private struct RecoveryKeySheet: View {
    let reveal: RecoveryReveal

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Account ID") {
                        Text(reveal.accountID)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Recovery key") {
                        Text(reveal.key)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Keep both somewhere safe. The recovery key is shown only once. It is how you get back into this account on a new device when no signed-in device is at hand.")
                }
                Section {
                    Button("I saved it") {
                        dismiss()
                        PairSync.shared.finishSignIn(replaceLocal: false)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Recovery key")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }
}

/// Joins with a code shown on a device that is already signed in.
private struct JoinWithCodeSheet: View {
    @Binding var joined: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    private var cleaned: String { PairSync.cleanCode(code) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("8-character code", text: $code)
                        .font(.system(.title3, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Shown on a device that is signed in: Settings, Pear.pair, Show pair code.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Pair this device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") { pair() }
                        .disabled(busy || cleaned.count != 8)
                }
            }
        }
    }

    private func pair() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await PairSync.shared.joinWithCode(code, deviceName: UIDevice.current.name)
                joined = true
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "That code didn't work."
            }
        }
    }
}

/// Joins an account with its ID and recovery key, for a device with nothing signed in.
private struct RecoverSheet: View {
    @Binding var joined: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var recoveryKey = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Account ID", text: $accountID)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Recovery key", text: $recoveryKey)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The recovery key is shown once, when the account is made. Spaces and dashes don't matter.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Recover account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recover") { recover() }
                        .disabled(busy || accountID.trimmingCharacters(in: .whitespaces).isEmpty || recoveryKey.isEmpty)
                }
            }
        }
    }

    private func recover() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await PairSync.shared.joinWithRecoveryKey(
                    accountID: accountID, recoveryKey: recoveryKey, deviceName: UIDevice.current.name)
                joined = true
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Those details didn't work."
            }
        }
    }
}

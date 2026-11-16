// The Machines page: one card per machine you work on (this Mac and every configured SSH machine),
// headed by "N of M reachable · X working · Y need you" and Check all now. This view wires the
// page's values (`MachinesPageBuilder`) and actions to the existing store functions: a chat row
// opens the chat in Chats; Attach checks a remote Claude chat is a background session and opens
// the existing Attach; New chat here opens the New chat sheet with that machine (this Mac: the
// current or main project); Open in Terminal opens the main project folder, Open SSH a Terminal
// login with remote monitoring's strict options; Update asks first, then runs the tool's updater;
// Clear empties Burro's cache for that machine; Retry now and Check all now check machines at once;
// Forget machine asks, then removes it; the pencil and "Add a machine" open the existing editor;
// Tailscale devices offer Add over SSH. Work runs only while the page is on screen: tool versions
// and Tailscale every minute (the store spaces them out), the status lines every 5 seconds, and
// cache totals when the page appears, after a clear, and when machines change.
import SwiftUI
import BurroCore

struct MachinesView: View {
    @Bindable var store: AppStore
    @State private var onScreen = false
    @State private var now = Date()
    @State private var copiesVersion = 0
    @State private var editing: RemoteHost?
    @State private var forgetting: RemoteHost?
    @State private var pendingUpdate: (harness: Harness, card: MachineCardModel)?
    private var machines: MachinesStore { store.machines }

    var body: some View {
        let model = MachinesPageBuilder.build(store: store, now: now)
        let actions = self.actions
        ScrollView {
            MachinesPage(model: model, actions: actions)
                .padding(.horizontal, 30).padding(.top, 6).padding(.bottom, 28)
                .frame(maxWidth: 1340).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            MachinesHeader(model: model, actions: actions).frame(maxWidth: 1340).frame(maxWidth: .infinity).background(AppAppearance.background)
        }
        .background(AppAppearance.background)
        .background(WindowOcclusionReader { onScreen = $0 })
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                machines.refresh(hosts: store.remoteHosts)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: onScreen) {
            while onScreen && !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: "\(onScreen)-\(copiesVersion)-\(store.remoteHosts.map { "\($0.id)\($0.destination)" })") {
            guard onScreen else { return }
            await machines.loadLocalCopies(store.remoteHosts)
        }
        .sheet(item: $editing) { host in RemoteHostEditor(host: host) { store.saveRemoteHost($0) } }
        .confirmationDialog(pendingUpdate.map { "Update \($0.harness.title) on \($0.card.name)?" } ?? "",
                            isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } }),
                            titleVisibility: .visible) {
            Button("Update") {
                if let pending = pendingUpdate { machines.update(pending.harness, machineID: pending.card.id, host: pending.card.host) }
                pendingUpdate = nil
            }
            Button("Cancel", role: .cancel) { pendingUpdate = nil }
        } message: {
            Text(pendingUpdate.map { "Runs `\($0.harness.command) \(($0.harness.updateArguments ?? []).joined(separator: " "))`\($0.card.isLocal ? "" : " over SSH"). Running chats keep the version they started with." } ?? "")
        }
        .confirmationDialog(forgetting.map { "Forget \($0.name)?" } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible) {
            Button("Forget machine", role: .destructive) {
                if let host = forgetting { store.removeRemoteHost(host.id) }
                forgetting = nil
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("Burro stops checking it and deletes what it copied from it: last-seen chats, transcript copies, images and videos. Nothing on the machine itself changes. You can add it again later.")
        }
    }

    private var actions: MachinesActions {
        var actions = MachinesActions()
        actions.openChat = { store.selectAgent($0) }
        actions.attach = { session, host in machines.attach(session, host: host) }
        actions.showChats = { store.page = .remote }
        actions.newChat = { card in
            if let host = card.host { store.openNewChat(LaunchDraft(machine: host.id)) }
            else { store.openNewChat(LaunchDraft(folder: store.currentLaunchProject?.path ?? store.mainProject?.path)) }
        }
        actions.openTerminal = { card in
            if let host = card.host { machines.openSSH(host) }
            else if let folder = store.mainProject?.path { machines.openTerminal(folder: folder) }
            else { machines.openTerminal(folder: NSHomeDirectory()) }
        }
        actions.update = { harness, card in pendingUpdate = (harness, card) }
        actions.clearCache = { card in
            guard let host = card.host else { return }
            Task { await store.clearRemoteCache(host.id); copiesVersion += 1 }
        }
        actions.retry = { card in if let host = card.host { store.requestRemoteCheck(host.id) } }
        actions.resume = { card in
            guard var host = card.host else { return }
            host.enabled = true
            store.saveRemoteHost(host)
        }
        actions.edit = { card in editing = card.host }
        actions.forget = { card in forgetting = card.host }
        actions.add = { destination in editing = RemoteHost(name: MachinesOverview.suggestedName(for: destination), destination: destination) }
        actions.addTailnet = { peer in editing = RemoteHost(name: peer.hostName, destination: peer.dnsName ?? peer.hostName) }
        actions.checkAll = {
            machines.refresh(hosts: store.remoteHosts, force: true)
            Task { await store.refreshRemotes() }
            copiesVersion += 1
        }
        actions.dismissMessage = { machines.message = nil }
        return actions
    }
}

struct PillButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background { Capsule().fill(hovering ? AppAppearance.raised : AppAppearance.surface).shadow(color: AppAppearance.shadow, radius: 6, y: 2) }
                .overlay(Capsule().strokeBorder(AppAppearance.separator))
        }.buttonStyle(.plain).onHover { hovering = $0 }
        .fixedSize() // a pill never wraps its title
    }
}

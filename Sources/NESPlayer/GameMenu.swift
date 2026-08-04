import NESCore
import SwiftUI

/// In-game overlay: save states, sound, and reset.
///
/// Deliberately out of the way. The app is a game, not an emulator front-end,
/// so the only permanent chrome is one small translucent button; everything
/// else appears on demand and pauses the game while it is up.
struct GameMenu: View {
    @ObservedObject var host: EmulatorHost
    @ObservedObject var store: SaveStateStore
    @Binding var isPresented: Bool
    @Binding var showDiagnostics: Bool
    @Binding var showTapTest: Bool
    /// Which row the controller has selected. Ignored by touch, which taps
    /// what it wants directly.
    @Binding var selection: Int
    /// Where controller input goes while this is up.
    let router: MenuRouter

    @State private var confirmingReset = false
    @AppStorage("nesSystemControls") private var useSystemControls = false
    /// Shared with `GameLauncher` by key; the screen it controls is shown
    /// before this menu can exist, so there is nothing to bind through.
    @AppStorage("nesCloudScreen") private var showCloudScreen = true
    /// Read by `SaveToast` through the same key; the toast is a sibling view
    /// rather than a child, so there is nothing to bind through.
    @AppStorage("nesSaveNotices") private var showSaveNotices = true

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 20) {
                header
                slotGrid
                controls
            }
            .padding(24)
            .frame(maxWidth: 460)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(20)
        }
        .transition(.opacity)
        .onAppear {
            // The menu drives its own selection: tvOS will not do it for us
            // once the app has claimed the controller. See `MenuRouter`.
            selection = 0
            router.resetSteering()
            router.move = { delta in
                selection = (selection + delta + rowCount) % rowCount
            }
            router.activate = { activateSelection() }
            router.close = { dismiss() }
            router.isOpen = true
        }
        .onDisappear { router.isOpen = false }
    }

    private var header: some View {
        HStack {
            Text(host.title)
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .menuHighlight(selection == closeRow)
        }
    }

    private var slotGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVE STATES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            // Fixed four columns so the slots always read as one row rather
            // than wrapping 3 + 1.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
            ) {
                ForEach(store.slots) { slot in
                    SlotView(
                        slot: slot,
                        onSave: {
                            store.save(host.nes, frame: host.frame, to: slot.index)
                        },
                        onLoad: {
                            if store.load(into: host.nes, from: slot.index) {
                                host.refreshFrameAfterStateChange()
                                dismiss()
                            }
                        })
                        .menuHighlight(selection == slot.index)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $host.isMuted) {
                Label("Mute", systemImage: host.isMuted ? "speaker.slash" : "speaker.wave.2")
            }
            .menuHighlight(selection == Self.slotRows)
            Toggle(isOn: $host.autoResumeEnabled) {
                Label("Resume where I left off", systemImage: "arrow.uturn.backward.circle")
            }
            .menuHighlight(selection == Self.slotRows + 1)
            Toggle(isOn: $showCloudScreen) {
                Label("iCloud loading screen", systemImage: "icloud")
            }
            .menuHighlight(selection == Self.slotRows + 2)
            Toggle(isOn: $showSaveNotices) {
                Label("\"Game saved\" messages", systemImage: "bell.badge")
            }
            .menuHighlight(selection == Self.slotRows + 3)
            Toggle(isOn: $showDiagnostics) {
                Label("Diagnostics", systemImage: "waveform.path.ecg")
            }
            .menuHighlight(selection == Self.slotRows + 4)
            #if os(iOS)
                Toggle(isOn: $useSystemControls) {
                    Label("Apple on-screen controls", systemImage: "gamecontroller")
                }
            #endif

            #if os(iOS)
                Button {
                    // Close the menu but leave the game running: a
                    // responsiveness test with the emulator paused would
                    // remove the load it is meant to measure.
                    isPresented = false
                    host.isPaused = false
                    showTapTest = true
                } label: {
                    Label("Tap test", systemImage: "hand.tap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            #endif

            Button {
                if confirmingReset {
                    host.reset()
                    dismiss()
                } else {
                    confirmingReset = true
                }
            } label: {
                Label(confirmingReset ? "Tap again to confirm" : "Reset game",
                      systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(confirmingReset ? Color.red : Color.primary)
            }
            .buttonStyle(.bordered)
            .tint(confirmingReset ? .red : .gray)
            .menuHighlight(selection == resetRow)
        }
        .font(.subheadline)
    }

    /// Rows the controller can land on, in visual order: four save slots, the
    /// toggles, then reset and close.
    static let slotRows = 4
    private var toggleRows: Int {
        #if os(iOS)
            6
        #else
            5
        #endif
    }

    var rowCount: Int { Self.slotRows + toggleRows + 2 }
    private var resetRow: Int { rowCount - 2 }
    private var closeRow: Int { rowCount - 1 }

    /// Performs whatever the selected row does.
    func activateSelection() {
        switch selection {
        case 0..<Self.slotRows:
            let slot = store.slots[selection]
            if slot.isEmpty {
                store.save(host.nes, frame: host.frame, to: slot.index)
            } else if store.load(into: host.nes, from: slot.index) {
                host.refreshFrameAfterStateChange()
                dismiss()
            }
        case Self.slotRows: host.isMuted.toggle()
        case Self.slotRows + 1: host.autoResumeEnabled.toggle()
        case Self.slotRows + 2: showCloudScreen.toggle()
        case Self.slotRows + 3: showSaveNotices.toggle()
        case Self.slotRows + 4: showDiagnostics.toggle()
        case resetRow:
            if confirmingReset {
                host.reset()
                dismiss()
            } else {
                confirmingReset = true
            }
        case closeRow: dismiss()
        default: break
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) {
            isPresented = false
        }
        host.isPaused = false
    }
}

/// One save slot: thumbnail if occupied, tap to load, long-press or the badge
/// to overwrite.
private struct SlotView: View {
    let slot: SaveStateStore.Slot
    let onSave: () -> Void
    let onLoad: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.55))

                if let thumbnail = slot.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(4.0 / 3.0, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 72)
            .contentShape(Rectangle())
            .onTapGesture { slot.isEmpty ? onSave() : onLoad() }

            HStack(spacing: 4) {
                Text("\(slot.index + 1)")
                    .font(.caption2.weight(.bold))
                Spacer()
                if !slot.isEmpty {
                    Button(action: onSave) {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Text(slot.isEmpty ? "Empty" : Self.format(slot.savedAt))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }
}

private extension View {
    /// Draws the controller's selection. tvOS would normally supply a focus
    /// ring, but the app has taken the controller and with it the job of
    /// showing where you are.
    func menuHighlight(_ selected: Bool) -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.white : .clear, lineWidth: 3))
    }
}

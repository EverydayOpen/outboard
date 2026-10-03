import OutboardCore
import SwiftUI

// docs/DESIGN.md §6.5 (Drives), docs/MOTION.md §3.4 (no entrance). The guard's lamp and its words, two figures, every mounted drive
// (`DrivePickerView`), then the moved folders and the leftovers (`GuardView`). Everything comes from the one model: the drive count
// is the list's length, Moved is the active relocations' bytes. Written, not compiled.

struct DrivesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                figures
                DrivePickerView()
                GuardView()
            }
            .padding(Space.xxl)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { Dusk(strength: 0.6) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Drives").font(.system(size: 28, weight: .semibold)).tracking(-0.5)
                Text("The drives Outboard can see, and the folders you have moved to them.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            GuardLamp(lit: model.guardLit, label: model.guardLabel)
            if let note = model.guardNote {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var figures: some View {
        let moved = byteFigure(model.movedBytes)
        return HStack(alignment: .top, spacing: Space.xxl) {
            Metric("Drives", Format.number(model.volumes.count))
            Metric("Moved", moved.value, unit: moved.unit)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .animation(Motion.standard(reduceMotion), value: model.movedBytes)
    }
}

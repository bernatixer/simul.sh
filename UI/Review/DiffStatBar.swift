import SwiftUI

/// "+A −R" then GitHub's five squares (see FileDiff.squares).
struct DiffStatBar: View {
    let added: Int
    let removed: Int
    @Environment(\.reviewPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let (green, red) = FileDiff.squares(added: added, removed: removed)
        let roll: Animation? = reduceMotion ? nil : .snappy(duration: 0.25)
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("+\(added)").foregroundStyle(palette.addedText)
                    .contentTransition(.numericText(value: Double(added)))
                    .animation(roll, value: added)
                Text("−\(removed)").foregroundStyle(palette.removedText)
                    .contentTransition(.numericText(value: Double(removed)))
                    .animation(roll, value: removed)
            }
            .font(.system(size: 11, design: .monospaced))
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < green ? palette.addedSquare : i < green + red ? palette.removedSquare : palette.secondaryText.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .animation(roll, value: [green, red])
        }
        .fixedSize()
    }
}

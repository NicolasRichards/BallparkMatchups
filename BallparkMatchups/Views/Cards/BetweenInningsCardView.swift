import SwiftUI

struct BetweenInningsCardView: View {
    let info: BetweenInningsInfo
    @State private var currentLine = ""

    private let genericLines = [
        "Beer line's shorter now.",
        "Stretch your legs.",
        "Peanuts. Always peanuts.",
        "Cracker Jack situation.",
        "Bathroom window: closing fast.",
        "Grab a hot dog.",
        "Pretzel run.",
        "The wave is somebody else's problem.",
        "Good time for a scorecard check.",
        "Nachos window: open.",
        "Water. You'll thank yourself later.",
        "Check the bullpen.",
        "Sunflower seeds are a way of life.",
        "The scoreboard doesn't lie.",
        "A cotton candy person passes. Respect.",
        "Foam finger moment.",
        "The organ deserves better attendance.",
        "Standing up counts as exercise.",
        "This is when you text back.",
        "The vendor knows what you want."
    ]

    private var inningLabel: String {
        switch info.inningState {
        case "End":
            return "END OF THE \(ordinal(info.inning).uppercased())"
        case "Middle":
            if info.inning == 7 {
                return "SEVENTH INNING STRETCH"
            }
            return "MIDDLE OF THE \(ordinal(info.inning).uppercased())"
        default:
            return "INNING BREAK"
        }
    }

    private var isSeventhStretch: Bool {
        info.inningState == "Middle" && info.inning == 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(inningLabel)
                .primaryFont(size: 20, weight: .bold)

            Text(isSeventhStretch ? "Take Me Out to the Ball Game." : currentLine)
                .labelFont(size: 17)
                .fixedSize(horizontal: false, vertical: true)

            if !isSeventhStretch {
                Text("(\(info.nextTeam) coming to bat)")
                    .labelFont(size: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .onAppear { pickMessage() }
    }

    private func pickMessage() {
        currentLine = genericLines.randomElement() ?? genericLines[0]
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }
}

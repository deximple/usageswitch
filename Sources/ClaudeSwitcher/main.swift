import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if let i = arguments.firstIndex(of: "--cli") {
    exit(CLI.run(Array(arguments[(i + 1)...])))
}
ClaudeSwitcherApp.main()

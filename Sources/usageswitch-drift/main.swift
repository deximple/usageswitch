import Foundation
import SwitcherCore
import VendorDrift

// usageswitch-drift — checks the vendor CLIs installed on this Mac against what UsageSwitch
// reads from them. Prints a Markdown report (or, with --update-snapshot, the Codex protocol
// snapshot) to stdout and writes no file itself. See scripts/vendor-drift.sh.
//
// Exit status: 0 no drift, 1 drift found, 2 the tool could not run.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("usageswitch-drift: \(message)\n\(DriftArguments.usage)\n".utf8))
    exit(2)
}

let arguments: DriftArguments
switch DriftArguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): arguments = parsed
case .failure(.missingValue(let flag)): fail("\(flag) needs a value")
case .failure(.unknown(let argument)): fail("unknown argument \(argument)")
case .failure(.workRequired): fail("--work is required")
}
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: arguments.work, isDirectory: &isDirectory), isDirectory.boolValue
else { fail("--work must be an existing folder") }

let environment = SwitcherEnvironment.live()
let frozen = arguments.snapshot.flatMap { FileManager.default.contents(atPath: $0) }
    .flatMap(CodexProtocolSnapshot.init(json:))
if let path = arguments.snapshot, frozen == nil, !arguments.updateSnapshot {
    fail("the snapshot at \(path) is missing or unreadable")
}
let run = DriftRun(home: environment.home, path: ProcessInfo.processInfo.environment["PATH"] ?? "",
                   bundledCodexCLI: environment.codexCLI, frozen: frozen,
                   workDirectory: URL(fileURLWithPath: arguments.work, isDirectory: true),
                   runner: SystemUsageProcessRunner())

if arguments.updateSnapshot {
    guard let snapshot = run.installedSnapshot(cli: arguments.codex.map { URL(fileURLWithPath: $0) }) else {
        fail("no Codex CLI found, or it could not generate its schema")
    }
    guard snapshot.missingFromContract.isEmpty else {
        fail("not freezing: the schema lacks \(snapshot.missingFromContract.joined(separator: ", "))")
    }
    FileHandle.standardOutput.write(snapshot.json() + Data("\n".utf8))
    exit(0)
}

let report = run.report()
FileHandle.standardOutput.write(Data(Redaction.scrub(report.markdown(), home: environment.home).utf8))
exit(report.hasDrift ? 1 : 0)

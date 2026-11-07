import Foundation
import KirjutaCore

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
    let rest = Array(args[(i + 2)...]).filter { !$0.hasPrefix("-") }
    exit(SelfTest.run(file: args[i + 1], lang: rest.first ?? "auto", model: rest.count > 1 ? rest[1] : Settings.model,
                      realtime: args.contains("--realtime")))
}
if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
    exit(SelfTest.importTest(file: args[i + 1], lang: args.count > i + 2 && !args[i + 2].hasPrefix("-") ? args[i + 2] : "auto"))
}
if args.contains("--words") { exit(SelfTest.words()) }
if let i = args.firstIndex(of: "--dictate"), i + 1 < args.count { exit(SelfTest.dictate(file: args[i + 1])) }
if let i = args.firstIndex(of: "--bench") {
    exit(Bench.run(Array(args[(i + 1)...])))
}
KirjutaApp.main()

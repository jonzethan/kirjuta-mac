import Foundation
import KirjutaCore

// `Kirjuta --selftest fail.wav [et|en] [q8_0]`: sama toru mis mikrofonil (Chunker -> whisper -> TextCleaner),
// aga heli tuleb failist. Ilma aknata, kontrolliks.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
    exit(SelfTest.run(file: args[i + 1], lang: args.count > i + 2 ? args[i + 2] : "et",
                      model: args.count > i + 3 ? args[i + 3] : Settings.model))
}
KirjutaApp.main()

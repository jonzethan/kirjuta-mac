import Foundation
import KirjutaCore

/// ggml-metal võib mudeli laadimisel kutsuda abort() (nt macOS 14.5: „pre-allocated tensor … cannot run
/// the operation“). abort()-ist ei saa samas protsessis taastuda, seega proovitakse iga varianti
/// eraldi alamprotsessis (`Kirjuta --probe-gpu <backend> <mudel>`) ja võetakse esimene, mis töötab.
/// Tulemus jäetakse meelde (macOS versioon + äpi versioon + mudel), nii et proov tehakse ühe korra.
enum GpuProbe {
    /// Alamprotsessi pool: laeb mudeli, teeb soojenduse, lõpetab koodiga 0. abort() -> kood 3, ilma crash-raportita.
    static func runChild(backend: String, path: String) -> Int32 {
        signal(SIGABRT) { _ in _exit(3) }
        signal(SIGSEGV) { _ in _exit(4) }
        signal(SIGBUS) { _ in _exit(4) }
        guard let b = WhisperEngine.Backend(rawValue: backend) else { return 2 }
        guard WhisperEngine.shared.load(path: path, backend: b) else { return 1 }
        WhisperEngine.shared.unload()
        return 0
    }

    /// Valib varundi: kasutaja seade või (auto) esimene, mis alamprotsessis läbi läheb.
    static func choose(modelPath: String) -> WhisperEngine.Backend {
        if let forced = WhisperEngine.Backend(rawValue: Settings.gpu) { return forced }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let ver = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        let key = "\(os)|\(ver)|\((modelPath as NSString).lastPathComponent)"
        if let s = Settings.gpuProbe[key], let b = WhisperEngine.Backend(rawValue: s) { return b }

        var chosen = WhisperEngine.Backend.cpu
        for b in [WhisperEngine.Backend.metal, .metalNoFA] {
            let code = runProbe(b, modelPath)
            AppLog.i("GPU", "proov \(b.rawValue): kood \(code)")
            if code == 0 { chosen = b; break }
            if code == 1 { break } // mudel ise ei laadi – pole GPU viga, ära proovi edasi
        }
        var cache = Settings.gpuProbe
        cache[key] = chosen.rawValue
        Settings.gpuProbe = cache
        AppLog.i("GPU", "valitud \(chosen.rawValue) (\(os))")
        return chosen
    }

    private static func runProbe(_ b: WhisperEngine.Backend, _ path: String) -> Int32 {
        guard let exe = Bundle.main.executableURL else { return -1 }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--probe-gpu", b.rawValue, path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationReason == .exit ? p.terminationStatus : 128 + p.terminationStatus
    }
}

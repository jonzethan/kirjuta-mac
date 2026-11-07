# Kirjuta Mac – native macOS äpp (Swift + SwiftUI + whisper.cpp/Metal)

Maci versioon kasutaja Androidi äpist **Kirjuta Offline**. Täiesti võrguühenduseta eesti/inglise keele
kõnetuvastus TalTechi Whisper-mudeliga. Kuulab **mikrofoni (Mina)** ja **süsteemiheli (Nemad, nt Teams)**.

**Kõik taust, mõõtmised, whisper.cpp nipid ja funktsioonide nimekiri on failis `RAPORT.md`. Loe see enne tööd
läbi ja järgi seda.** Androidi kood on viiteks kaustas `~/whisper-android/kirjuta-app` (vt allpool).

## Suhtlus
- Vasta kasutajale **eesti keeles**, lühidalt ja konkreetselt. Pärast iga etappi 1–2 lauset, mis valmis sai ja
  kuidas ta saab seda ise proovida.
- Kasutaja on laeva mehaanik ja magistrant, programmeerimises kesktase. Selgita Maci-spetsiifilised sammud
  (õigused, allkirjastamine) lihtsalt.

## Seos Androidi projektiga (`~/whisper-android`)
- **ÄRA MUUDA midagi kaustas `~/whisper-android`.** See on ainult lugemiseks: lähtekood viiteks, mudelid,
  testhelid. Androidi `whisper.cpp/build` on CLI ehitus – ära ehita seda ümber.
- Selles projektis on sümbollingid (loo need, kui puuduvad, ja lisa `.gitignore`-i):
  - `models` → `~/whisper-android/models` (TalTechi mudelid: f16, q8_0, q5_0, q4_0)
  - `diar-models` → `~/whisper-android/third_party/diar` (sherpa-onnx ONNX-mudelid)
  - `testaudio` → `~/whisper-android/audio` (`test-29s.wav`, `johanna.wav` + `johanna.tsv` jne)
- Androidi loogika portimisel (Engine.kt, TextCleaner, Chunker, Refine/FileJobService, Diarizer, Data.kt)
  loe originaali `~/whisper-android/kirjuta-app/app/src/main/` alt ja hoia käitumine samasugune.
- **Salvestiste kaustavorming peab olema sama mis Androidis** (RAPORT.md p 4.3), et telefoni salvestised
  avaneksid Macis ja vastupidi. Maci lisa: `mic.wav` + `system.wav` (+ miksitud `audio.wav`), `segments.tsv`
  4. veerg = kõneleja; Mina/Nemad märgi nii, et Androidi äpp ei katkeks (nt kõneleja nr + `speakers.txt`
  `0=Mina`, `1=Nemad`). Kirjuta vorming ka faili `SESSION_FORMAT.md`.

## Reeglid
- Mudeleid, WAV-e ega ehitusväljundit **ei commiti** (`models`, `diar-models`, `testaudio`, `.build/`, `build/`,
  `*.app`, `*.wav`). Commiti iga valminud etapi lõpus väikeste, selgete commit'idega. **Ära push'i** ilma
  kasutaja loata.
- Äpp ei tohi käitusajal võrku kasutada.
- `sudo` vajab parooli – anna kasutajale käsk, ta käivitab ise (`! <käsk>`).
- Kui midagi vajab kasutaja klikki (macOS õiguste dialoog, Süsteemiseaded), ütle täpselt, kuhu klikkida.

## Keskkond
- MacBook Pro **M1, 16 GB**, **macOS 27.2**, Homebrew, zsh (conda `base` võib olla aktiivne – ära sellele toetu).
- Swift 6.4 Command Line Toolsist. **Xcode võib olla paigaldatud** – kontrolli `xcode-select -p` ja
  `xcodebuild -version`. Kui Xcode on olemas, kasuta Xcode projekti (või SwiftPM + `xcodebuild`), sest õigused,
  entitlements ja allkirjastamine on lihtsamad. Kui pole, ehita `swift build` + käsitsi `.app` + `codesign`
  ja ütle kasutajale, et Xcode teeks elu lihtsamaks.
- Allkirjasta **stabiilse identiteediga** (Xcode'i Apple Development sertifikaat või püsiv isetehtud
  koodiallkirjastamise sertifikaat võtmeahelas), muidu kaovad mikrofoni/süsteemiheli õigused iga ehitusega.

## whisper.cpp
- Lisa submodule'ina: `git submodule add https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp` ja võta
  **sama commit mis Androidis: `482279b`** (uuenda hiljem teadlikult, mitte juhuslikult).
- Ehita Metaliga staatiliseks teegiks (nt `cmake -B build-mac -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=ON`) ja seo Swiftiga C-mooduli / module map'i kaudu
  (lingi ka Metal, MetalKit, Accelerate, Foundation). Vali kõige lihtsam töökindel viis.
- Mudel vaikimisi **`models/taltech-et-turbo-q8_0.bin`** (kvaliteet = f16). Lase seadetes valida f16/q8_0/q5_0.
- Parameetrid **täpselt nagu RAPORT.md p 3.3**:
  - reaalaeg: greedy, `no_context=true`, `no_timestamps=false` (ajatemplid PEAVAD olema sees), `temperature_inc=0`,
    `suppress_blank=true`, `audio_ctx = max(640, sek*50+250)`, ≥1500 → 0.
  - täpne/TÄPSUSTA: beam 2, `audio_ctx=0`, `encoder_begin_callback` lubab ühe kodeerija käivituse, järgmine
    30 s aken algab viimase lõigu `t1`-st. `flash_attn=true`.
- TextCleaner: port Androidist (vaikuse hallutsinatsioonid „Aitäh.", „Tänan.", „Thank you for watching",
  korduvad laused/fraasid, võõra tähestikuga sõnad).

## Tehnoloogia (RAPORT.md p 5.3)
- UI: SwiftUI, menüüriba ikoon + põhiaken + (hiljem) ujuv reaalaja-aken.
- Mikrofon: `AVAudioEngine` → 16 kHz mono Float32. Kajaeemaldus `setVoiceProcessingEnabled(true)` lülitatav.
- Süsteemiheli: **Core Audio process tap** (`AudioHardwareCreateProcessTap` + aggregate device),
  Info.plist `NSAudioCaptureUsageDescription`; protsessi valik (Teams/Zoom/Chrome/kõik). Varu: ScreenCaptureKit.
- VAD: alusta Androidi energiapõhise Chunkeri pordiga (sama käitumine), Silero VAD (whisper.cpp sisseehitatud)
  lisa seadena hiljem.
- Kõnelejad: sherpa-onnx (C-API), samad mudelid `diar-models/`; ainult süsteemiheli voole.
- Failide dekodeerimine: AVFoundation.
- Üks whisperi töölõim, üks järjekord; iga tükk kannab `source` (mic/system) ja aega sessiooni algusest.

## Etapid (tee järjest, iga etapi lõpus näita kasutajale, kuidas proovida, ja commiti)
1. **Mõõtmine:** ehita whisper.cpp Metaliga, `whisper-cli` + `models/taltech-et-turbo-q8_0.bin` +
   `testaudio/test-29s.wav`. Mõõda aeg (ka f16, q5_0), võrdle teksti Androidiga. Kirjuta `TULEMUSED-MAC.md`.
2. **Minimaalne äpp:** SwiftUI aken, ⌘R alusta/lõpeta, mikrofon → Chunker → whisper → tekst lause haaval
   ekraanile, `audio.wav` + `segments.tsv` sessioonikausta.
3. **Süsteemiheli:** process tap, kaks voogu, sildid Mina/Nemad, `mic.wav` + `system.wav`, kaja käsitlus.
4. **Salvestised:** nimekiri päevade kaupa, mängija (lõigu klõps → heli koht), kustuta + võta tagasi, kinnita,
   eksport (TXT ajatemplitega/ilma, MD, SRT/VTT, heli, kopeeri).
5. **Import + TÄPSUSTA:** lohista helifail aknasse, täpne ülekirjutus taustal, ühe akna loogika.
6. **Kõnelejad:** sherpa-onnx süsteemiheli voole, nimede muutmine.
7. **Mugavus:** menüüriba, globaalne kiirklahv, ujuv aken, otsing, logi RTF-iga.
8. **Pakendamine:** `.app` `~/Applications` alla, allkirjastatud, õigused püsivad.

## UI stiil (RAPORT.md p 5.6)
Tume, monospace (SF Mono), vähe värve. Vasakul salvestised, paremal `[00:12:34] Mina: …`.
Ülariba: `● REC 00:12:34 | mic ▁▃▅ | sys ▂▆▃ | lag 0.8s | et | q8_0 | Metal`.
Kiirklahvid: ⌘R salvesta, ⌘E ekspordi, ⌘F otsi, ⌘T täpsusta.

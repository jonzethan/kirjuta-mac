# Kirjuta – projekti raport ja Maci versiooni lähteülesanne

*Koostatud 7.11.2026. Allikas: `~/whisper-android` (Androidi projekt).*

See dokument on kahes osas:
1. **Mis on tehtud** – Androidi äpp „Kirjuta Offline“, kuidas see töötab ja mida katsetades avastasime.
2. **Maci versioon** – mida saab uude projekti kaasa võtta, mis tuleb teha uuesti ja kuidas alustada.

---

## 1. Lühikokkuvõte

- TalTechi eesti keele Whisper (`whisper-large-v3-turbo-et-verbatim-2604`) töötab **täiesti võrguühenduseta** Xiaomi 13 telefonis ja on reaalajast kiirem.
- Valmis on päris äpp **Kirjuta Offline** (Kotlin + Jetpack Compose + whisper.cpp C-teek JNI kaudu). Äpp:
  - salvestab ka lukus ekraaniga ja kirjutab teksti lause haaval;
  - impordib helifaile;
  - teeb täpse ülekirjutuse (TÄPSUSTA);
  - eristab kõnelejaid (sherpa-onnx);
  - ekspordib teksti ja heli.
- Kõige tähtsamad avastused:
  - **q4_0** kvantiseering on telefonis ~3× kiirem kui q5_0 ja kvaliteet ei kannata.
  - Teksti jaoks peavad **ajatemplid olema sees**, muidu hakkab mudel kordama.
  - Reaalaeg tähendab Whisperiga lausehaaval töötlemist (VAD lõikab pausidest), mitte sõna-sõnalt voogedastust.
  - Pika faili puhul tuleb **iga 30 s akent arvutada ainult üks kord**. Pooleli jäänud saba läheb järgmisse aknasse.

---

## 2. Failid ja kaustad (kõik `~/whisper-android` all)

| Asukoht | Sisu |
|---|---|
| `kirjuta-app/` | Androidi äpi lähtekood. Kohalik git-repo, GitHubi pole üles pandud. |
| `whisper.cpp/` | whisper.cpp kloon (commit `482279b`, 30.10.2026), **Maci jaoks juba ehitatud Metaliga** (`build/bin/`). |
| `whisper.cpp/build/bin/whisper-cli` | Käsurea ülekirjutus Macis. |
| `whisper.cpp/build/bin/whisper-quantize` | Mudeli kvantiseerimine. |
| `whisper.cpp/build/bin/whisper-server` | HTTP server (kui vaja). |
| `models/taltech-et-turbo-f16.bin` | Algne TalTechi GGML mudel (1,62 GB). |
| `models/taltech-et-turbo-q8_0.bin` | 874 MB. Kvaliteet on sama mis f16-l. |
| `models/taltech-et-turbo-q5_0.bin` | 574 MB. |
| `models/taltech-et-turbo-q4_0.bin` | 474 MB, **kasutusel telefonis**. |
| `third_party/diar/` | Kõnelejate eristamise ONNX-mudelid (pyannote segmentation 3.0, wespeaker resnet34, 3D-Speaker). |
| `third_party/sherpa-onnx-…-2.0.1.aar` | sherpa-onnx Androidi teek (Macis seda ei kasuta, seal läheb C-API või Swift). |
| `audio/` | Testsalvestised (nt `test-29s.wav`, `kirjuta-test.mp3`, `johanna.wav` + `johanna.tsv`). |
| `TULEMUSED.md` | Teostatavuskatse mõõtmistulemused. |
| `PROJEKT.md` | Androidi äpi seis, ehitamise käsud ja lahtised asjad. |

Mudelifailid ei ole git'is ega tohi sinna sattuda.

### Mudeli tegemine nullist (kui on vaja uuesti)
```sh
cd ~/whisper-android/whisper.cpp
curl -L -o ../models/taltech-et-turbo-f16.bin \
  https://huggingface.co/TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604/resolve/main/ggml/ggml-model.bin
# suurus peab olema täpselt 1624555275 baiti
./build/bin/whisper-quantize ../models/taltech-et-turbo-f16.bin ../models/taltech-et-turbo-q8_0.bin q8_0
./build/bin/whisper-quantize ../models/taltech-et-turbo-f16.bin ../models/taltech-et-turbo-q4_0.bin q4_0
# test:
./build/bin/whisper-cli -m ../models/taltech-et-turbo-q8_0.bin -l et -f ../audio/test-29s.wav
```

---

## 3. Mõõtmised ja avastused

### 3.1 Kiirus Xiaomi 13 peal (ainult CPU)
| Mudel | Lõimed | Aeg 30 s akna kohta | RTF | Märkus |
|---|---|---|---|---|
| q5_0 | 6 | 27,5 s | ~1,1 | liiga aeglane |
| q8_0 | 6 | 14,0 s | ~0,56 | |
| **q4_0** | **6** | **9,8 s külmalt / ~15 s kuumalt** | **0,4–0,6** | **valitud** |
| q4_0, `audio_ctx=768` | 6 | ~5 s | ~0,35 | lühikesed tükid (≤15 s) |

RTF = töötlusaeg / heli pikkus. Kui RTF on alla 1, jõuab äpp reaalajas järele.

- **Kvaliteet:** f16, q8_0, q5_0 ja q4_0 andsid sama salvestise peal sõna-sõnalt sama teksti.
- **Kuumenemine:** 5 × 30 s järjest tõstis CPU temperatuuri 37 → 70 °C ja korpuse 37 → 47 °C. Aken muutus ~40% aeglasemaks.
- **Pikk TÄPSUSTA (5.11):** 48 min heli võttis 38 min kirjutamist ja 3,5 min kõnelejate eristamist. ~25% akendest võttis kaks korda kauem (vt 3.2 p 6). See on 7.11 parandatud, aga uut aega pole veel mõõdetud.

### 3.2 Tehnilised avastused (kehtivad ka Macis)
1. **Kodeerija võtab peaaegu kogu aja.** Iga aken on 30 s ja kodeerija aeg on sama, olgu heli 5 s või 30 s. Lühikese tüki saab kiirendada `audio_ctx` parameetriga (≈ sekundid × 50 + 250, vähemalt 640; 1500 = täis 30 s). Alla ~400 läheb mudel segadusse.
2. **Ajatemplid peavad olema sees** (`no_timestamps = false`). Ilma nendeta hakkab turbo-mudel lauseid kordama.
3. **Temperatuuri-kordused on väljas** (`temperature_inc = 0`). Kiirus on siis ennustatav. Kordused koristab tekstist eraldi TextCleaner.
4. **`no_context = true`.** Eelmise tüki tekst prompti ei lähe, sest muidu kanduvad vead edasi.
5. **Hallutsinatsioonid vaikuses.** Whisper kirjutab vaikuse peale „Aitäh.“, „Tänan.“, „Thank you for watching“. Seepärast:
   - VAD viskab vaikuse enne mudelit ära;
   - TextCleaner kustutab tüki, mis koosneb ainult sellisest fraasist;
   - TextCleaner kustutab korduvad laused, 1–6-sõnalised korduvad fraasid ja võõra tähestikuga (kirillitsa jne) sõnad.
6. **Pika faili töötlemine.** Whisper.cpp teeb tüki lõpetamata saba jaoks automaatselt **teise täisakna**, mis kahekordistab aja. Lahendus:
   - lubada ühe kodeerija käivituse (`encoder_begin_callback`);
   - alustada järgmist 30 s akent kohast, kus mudel viimase lõigu lõpetas (viimase lõigu `t1`).
7. **Kõnelejad:** sherpa-onnx pyannote + wespeaker, keelest sõltumatu. Automaatse rühmitamise lävi 0,8 andis 2 kõnelejaga salvestisel õige tulemuse. Kiirus: 100 s heli → 5–6 s.
8. **Androidi eripärad** (Macis ei kehti):
   - lukus ekraaniga pidi äpp olema esiplaaniteenus, muidu viis Android selle nõrkadele tuumadele (~15× aeglasem);
   - ehitada tuli i8mm-lippudega;
   - 8 lõime oli aeglasem kui 6.

### 3.3 whisper.cpp parameetrid, mida äpp kasutab
```c
// reaalaeg (lühikesed VAD-tükid)
p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
p.language = "et";            // või "en"
p.no_context = true;
p.no_timestamps = false;
p.temperature_inc = 0.0f;
p.suppress_blank = true;
p.audio_ctx = max(640, sek*50+250);  // >=1500 -> 0 (täis aken)

// täpne (failid, TÄPSUSTA)
p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
p.beam_search.beam_size = 2;
p.audio_ctx = 0;              // täis 30 s
p.encoder_begin_callback = only_first_encode;  // üks aken korraga, saba -> järgmisse aknasse
// konteksti parameetrid: flash_attn = true
```

---

## 4. Kuidas Androidi äpp töötab

### 4.1 Funktsioonid
- **Salvestamine** (punane nupp):
  - töötab esiplaaniteenusena, ka lukus ekraaniga;
  - heli läheb WAV-faili (16 kHz mono);
  - tekst ilmub lause haaval ~1–5 s pärast lause lõppu;
  - ekraanil on taseme-riba ja mahajäämise näit.
- **EST | ENG** keelevalik (sama mudel, muutub ainult keeleparameeter).
- **Avaleht:**
  - salvestised päevade kaupa;
  - libista vasakule = kustuta (VÕTA TAGASI 5 s jooksul);
  - libista paremale = kinnita üles.
- **Salvestise vaade:**
  - helimängija;
  - lõigu puudutus hüppab heli selle kohani;
  - eksport TEKST / HELI / KOPEERI.
- **+ HELIFAIL:** WAV/MP3/M4A jne import, dekodeerimine 16 kHz-ks ja täpne ülekirjutus taustal.
- **TÄPSUSTA:** kogu salvestis kirjutatakse uuesti täis 30 s akende ja beam 2-ga. Reaalajas tekkinud tekst arhiveeritakse (`segments.live.tsv`).
- **KÕNELEJAD:**
  - automaatne või 2–5 kõnelejat;
  - värvilised sildid;
  - nime muutmine („Kõneleja 1“ → „Kapten“);
  - eksport nimedega;
  - piir 90 min, sest kogu heli peab olema mälus.
- **Logi:** `kirjuta.log` (iga tüki pikkus, aeg, RTF).

### 4.2 Andmevoog reaalajas
```
Mikrofon 16 kHz mono (30 ms kaadrid)
   ├─> WavWriter  -> audio.wav (päist uuendatakse iga 5 s, et katkestus faili ei rikuks)
   └─> Chunker (energiapõhine VAD)
         müratase jälgitakse; kõne = RMS > max(müra*1.8, 120)
         paus ≥ 420 ms ja tükk ≥ 1,5 s  -> tükk valmis (+300 ms eelheli)
         tükk ≥ 12 s -> lõika vaikseimast kohast viimase 4 s sees
         ainult vaikus -> ära
   -> järjekord -> 1 whisperi lõim (kui maha jääb: liida järjekorras tükid kuni 28 s)
   -> Engine.transcribe (greedy, audio_ctx tüki järgi) -> TextCleaner
   -> segments.tsv + ekraan
```

### 4.3 Andmete vorming (iga salvestis on oma kaust)
```
sessions/2026-11-05_14-48-12/
  audio.wav            16 kHz mono 16-bit
  segments.tsv         algus_ms \t lõpp_ms \t tekst [\t kõneleja_nr]
  segments.live.tsv    reaalaja-tekst pärast TÄPSUSTA't
  lang                 et | en
  title                (failide puhul)
  speakers.txt         0=Kapten\n1=Mehaanik
  pinned               olemas = üles kinnitatud
```
See vorming sobib otse ka Maci äppi. Siis saab telefoni salvestisi Macis avada ja vastupidi.

### 4.4 Koodi ülesehitus (`kirjuta-app/app/src/main/`)
| Fail | Mida teeb | Macis |
|---|---|---|
| `cpp/jni.c` | whisper.cpp kutsumine, parameetrid, ühe akna piirang | **loogika üle**, Swiftis kutsutakse C-API-t otse |
| `cpp/CMakeLists.txt` | ehitab whisper.cpp (ARM-lipud) | asendub: Macis Metal + SwiftPM |
| `engine/Engine.kt` | `audio_ctx` valik, TextCleaner, logi | **loogika üle** (Swifti) |
| `engine/Diarizer.kt` | sherpa-onnx kõnelejad + lõikudele määramine | **loogika üle**, sherpa-onnx C-API/Swift |
| `audio/Audio.kt` | WavWriter/Reader, Chunker (VAD) | **loogika üle** või asenda Silero VAD-iga |
| `audio/Decoder.kt` | MP3/M4A → 16 kHz WAV | Macis AVFoundation (`AVAudioFile` + `AVAudioConverter`) |
| `RecordingService.kt` | mikrofon, järjekord, mahajäämisel liitmine | uus: AVAudioEngine + süsteemiheli |
| `FileJobService.kt` | import, TÄPSUSTA tsükkel, kõnelejad | **loogika üle** |
| `data/Data.kt` | sessioonid, seaded, prügikast, eksport | **loogika üle** |
| `ui/*.kt` | Compose UI | uus: SwiftUI |

---

## 5. Maci versioon – lähteülesanne

### 5.1 Eesmärk
Maci äpp, mis töötab samal põhimõttel nagu Androidi äpp:
- native, minimaalne, „arendaja tööriista“ stiilis liides;
- täiesti võrguühenduseta;
- kirjutab üles **nii mikrofoni (mina) kui ka arvutist tuleva heli (nt Teamsi vestluskaaslane)**.

### 5.2 Sinu Mac
- **Apple M1, 16 GB RAM, macOS 27.2.**
- Installitud on ainult **Command Line Tools** (Swift 6.4), **täit Xcode'i pole**.
  - SwiftUI äpi saab ehitada ka ilma Xcode'ita: `swift build` + käsitsi `.app` kaust + `codesign`.
  - Xcode'iga on mugavam (õiguste dialoogid, allkirjastamine, debugger). Soovitus: paigalda App Store'ist Xcode.

### 5.3 Soovitatud tehnoloogia
| Osa | Valik | Miks |
|---|---|---|
| Keel / UI | **Swift + SwiftUI** (menüüriba ikoon + aken) | native, väike, kiire |
| Kõnetuvastus | **whisper.cpp + Metal** (GPU), sama TalTechi mudel | M1 GPU on telefonist kordades kiirem |
| Mudel | **q8_0** (874 MB) või f16 | Macis on mälu ja kiirust küllalt, q4_0 kiirtee pole vajalik |
| Mikrofon | `AVAudioEngine` (soovi korral `setVoiceProcessingEnabled(true)` kaja eemalduseks) | |
| Süsteemiheli | **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) | ainult heli, küsib „System Audio Recording“ õigust, saab valida ainult Teamsi/Zoomi protsessi |
| (varu) | ScreenCaptureKit (`SCStream`, `capturesAudio = true`) | vajab ekraanisalvestuse õigust |
| VAD | whisper.cpp sisseehitatud **Silero VAD** (`models/download-vad-model.sh`) või Androidi Chunker | Silero on mürakindlam |
| Kõnelejad | sherpa-onnx (C-API / Swift näited) – samad ONNX-mudelid `third_party/diar/` | |
| Failide dekodeerimine | AVFoundation | MP3/M4A/WAV/video |

Kiirus Macis pole veel mõõdetud. M1 + Metal peaks tegema 30 s akna ~1–3 sekundiga, ehk reaalajast palju kiiremini. Esimene samm uues projektis: mõõta `whisper-cli`-ga.

### 5.4 Suur eelis: kaks eraldi helivoogu = kõnelejad tasuta
Mikrofon ja süsteemiheli tulevad eraldi. Seega on iga lõigu juures kohe teada, kes rääkis:
- **„Mina“** = mikrofon;
- **„Nemad“** = süsteemiheli.

Selleks pole kõnelejate eristamist vaja. Diariseerimist läheb vaja ainult siis, kui süsteemiheli poolel on mitu inimest (Teamsi koosolek), ja seda saab teha ainult sellel voolul.

Ettevaatust:
- **Kaja.** Kui kasutad kõlareid, kuuleb mikrofon ka vestluskaaslast ja sama tekst tuleb kaks korda. Lahendused:
  - kõrvaklapid (lihtsaim);
  - `setVoiceProcessingEnabled(true)` (Apple'i kajaeemaldus);
  - kui mõlemas voos on samal ajal sarnane tekst, jäta alles ainult süsteemiheli oma.
- **Salvestamine:** hoia kaks eraldi WAV-faili (`mic.wav`, `system.wav`) ja vajadusel ka kokku miksitud `audio.wav` kuulamiseks.
- **Õigused:** Mikrofon (`NSMicrophoneUsageDescription`) ja süsteemiheli (`NSAudioCaptureUsageDescription`). Allkirjastamata äpil võivad õigused iga ümberehitusega kaduda, seega allkirjasta ehitamisel kas stabiilse ad-hoc identiteediga või Xcode'i arendajasertifikaadiga.

### 5.5 Funktsioonid (Androidiga võrdsed + Maci lisad)
**Samad mis Androidis:**
- [ ] Salvestamine, tekst lause haaval, WAV salvestatakse.
- [ ] EST / ENG.
- [ ] Salvestiste nimekiri päevade kaupa, kustutamine koos tagasivõtmisega, kinnitamine.
- [ ] Helimängija, lõigu klõps hüppab heli selle kohani.
- [ ] Eksport: tekst (ajatemplitega / ilma), heli, kopeerimine.
- [ ] Helifaili import (lohista aknasse).
- [ ] TÄPSUSTA (täis aknad + beam, ühe akna loogika).
- [ ] Kõnelejad + nimede muutmine.
- [ ] Logi kiirusega (RTF).

**Uued Macis:**
- [ ] **Allika valik:** mikrofon / süsteemiheli / mõlemad (vaikimisi mõlemad). Süsteemiheli puhul saab valida rakenduse (Teams, Zoom, Chrome…).
- [ ] **Sildid „Mina“ / „Nemad“** voogude järgi automaatselt.
- [ ] Menüüriba ikoon + **globaalne kiirklahv** salvestamise alustamiseks/lõpetamiseks.
- [ ] Ujuv väike aken reaalaja-tekstiga koosoleku ajal (alati peal, poolläbipaistev).
- [ ] Eksport Markdowni (sobib otse märkmetesse) ja SRT/VTT subtiitrid.
- [ ] Otsing kõigist salvestistest.
- [ ] Salvestiste kausta ühilduvus Androidiga (vt 4.3).
- [ ] (hiljem) kokkuvõte kohaliku LLM-iga (nt llama.cpp), endiselt ilma internetita.

### 5.6 Kasutajaliidese stiil („software engineer“)
- Tume teema, monospace font (SF Mono / JetBrains Mono), vähe värve, värv ainult staatuse kohta (REC punane, kõneleja värvid).
- Vasakul salvestiste nimekiri, paremal tekst ajatemplitega: `[00:12:34] Mina: …`.
- Ülal üks rida: `● REC 00:12:34 | mic ▁▃▅ | sys ▂▆▃ | lag 0.8s | et | q8_0 | Metal`.
- Kõik peamised tegevused klaviatuurilt: `⌘R` salvesta, `⌘E` ekspordi, `⌘F` otsi, `⌘T` täpsusta.

### 5.7 Arhitektuur (ettepanek)
```
KirjutaMac/
  Package.swift (või Xcode projekt)
  Sources/
    CWhisper/            whisper.cpp (git submodule või viide ~/whisper-android/whisper.cpp), Metal
    Engine/
      Whisper.swift      kontekst, transcribe(samples, lang, accurate) – parameetrid nagu 3.3
      TextCleaner.swift  port Engine.kt-st
      Refine.swift       TÄPSUSTA tsükkel (üks aken, saba järgmisse aknasse)
      Diarizer.swift     sherpa-onnx
    Audio/
      MicCapture.swift       AVAudioEngine -> 16 kHz mono
      SystemCapture.swift    Core Audio process tap -> 16 kHz mono
      Chunker.swift          VAD (port või Silero)
      WavIO.swift
    Data/
      Sessions.swift     sama kaustavorming kui Androidis
    UI/
      App.swift, MainWindow.swift, MenuBar.swift, LiveOverlay.swift
```
- **Üks whisperi lõim, kaks järjekorda:** mikrofoni ja süsteemiheli tükid lähevad ühte järjekorda, kus iga tükk kannab silti `source` ja ajatemplit. Metali peal jõuab üks kontekst mõlemad voogud ära teha.
- **Ajad** loetakse sessiooni algusest, et kahe voo lõike saaks ajajärjekorras kokku panna.

### 5.8 Etapid uues projektis
1. Kopeeri või viita mudel (`q8_0`) ja whisper.cpp. Mõõda `whisper-cli` + Metal kiirus Macis.
2. Minimaalne SwiftUI äpp: mikrofon → Chunker → whisper → tekst ekraanile.
3. Süsteemiheli (process tap), kaks voogu, sildid Mina/Nemad, kaks WAV-i.
4. Salvestiste nimekiri, mängija, eksport (andmevorming nagu Androidis).
5. Failiimport + TÄPSUSTA.
6. Kõnelejad (sherpa-onnx) süsteemiheli voole.
7. Menüüriba, kiirklahv, ujuv aken, otsing.
8. `.app` pakendamine ja allkirjastamine, et õigused püsiksid.

### 5.9 Uue projekti alustamine Claude Code'iga
```sh
mkdir -p ~/kirjuta-mac && cd ~/kirjuta-mac
cp ~/Desktop/Kirjuta-raport.md ./RAPORT.md
claude
```
Esimene sõnum Claude'ile võib olla näiteks:
> Loe RAPORT.md. Tahan Maci native äppi (Swift + SwiftUI), mis on sama mis mu Androidi Kirjuta Offline, aga kuulab nii mikrofoni kui ka süsteemiheli (Teams). Mudel ja whisper.cpp on olemas `~/whisper-android/` all. Alusta etapist 1 ja 2 (punkt 5.8). Kirjuta CLAUDE.md selle projekti jaoks. Vasta eesti keeles.

Hea oleks lisada uude projekti `CLAUDE.md`, kus on kirjas: suhtlus eesti keeles; mudelid `~/whisper-android/models/` (ära commiti); whisper.cpp parameetrid punktist 3.3; ära muuda `~/whisper-android` projekti.

---

## 6. Androidi lahtised asjad (kui tagasi tuled)
- Mõõta parandatud TÄPSUSTA kiirus (7.11 paigaldatud). Ootus on 48 min heli kohta ~25 min ja logis ei tohiks enam olla ~30 s aknaid.
- 7.11 muudatused ei ole veel commititud (`kirjuta-app`).
- Masinaruumi müra: energia-VAD ei pruugi pause leida, sel juhul aitaks Silero VAD.
- Kõnelejate täpsus, kui rääkija vahetub keset lauset (vaja sõnataseme ajatempleid).
- Telefonist võib kustutada: `adb shell rm -rf /data/local/tmp/w` (1,9 GB) ja `adb uninstall com.whispercppdemo`.

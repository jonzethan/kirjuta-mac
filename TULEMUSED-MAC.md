# Mõõtmised Macis (etapp 1)

*7.11.2026 · MacBook Pro M1 16 GB · macOS 27.2 · whisper.cpp `482279b` (sama mis Androidis), Metal + flash attention.*

Ehitus (`vendor/whisper.cpp/build-mac`, staatilised teegid):
```sh
cd vendor/whisper.cpp
cmake -B build-mac -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2
cmake --build build-mac -j 8
```

## test-29s.wav (29 s), `whisper-cli -l et`, ajatemplid sees, `-nf` (temperature_inc=0)
Aeg = `total time` (sisaldab mudeli laadimist ja Metali käivitust). Kodeerija käis 2 korda (29 s fail → whisper.cpp teeb
saba jaoks teise akna, vt RAPORT 3.2 p 6), üks kodeerija käivitus ≈ **1,6 s**.

| Mudel | greedy | beam 2 | beam 5 | laadimine | kodeerija (1 aken) |
|---|---|---|---|---|---|
| **q8_0** | **4,7 s** | 4,8 s | 5,2 s | 0,33 s | 1,69 s |
| f16 | 5,1 s | 5,3 s | 6,0 s | 0,57 s | 1,66 s |
| q5_0 | 4,7 s | 5,0 s | 5,5 s | 0,20 s | 1,80 s |
| q4_0 | 4,2 s | 4,7 s | 5,0 s | 0,17 s | 1,62 s |

- **RTF ≈ 0,15** (q8_0, greedy) – ~6× reaalajast kiirem. Telefonis q4_0 oli 0,4–0,6.
- Metalil pole kvantiseeringul peaaegu vahet (kodeerija on GPU-l ~sama kiire). Seega Macis **q8_0** (= f16 kvaliteet, väiksem).
- Lühikesed tükid (reaalaeg), q8_0 greedy, `audio_ctx = max(640, s*50+250)`:

| Tükk | audio_ctx=0 | audio_ctx=640 |
|---|---|---|
| c_a.wav 3,9 s | 2,09 s (enc 1,64) | **1,02 s** (enc 0,59) |
| c_d.wav 1,0 s | 2,01 s | 1,17 s |

  → reaalajas jõuab tekst ekraanile ~1 s pärast lause lõppu.

## Tekst
- Maci ehitus ja Androidi kaustas olev Maci CLI (`~/whisper-android/whisper.cpp/build`) andsid q8_0 greedy-ga **baidi täpsusega sama teksti**.
- Fail sisaldab sama lauset ~3 korda. greedy: „Tere, tere. See on nüüd neljas test, siis transcribing'ing akenduse jaoks. Vaatame, kuidas välja tuleb ja loodame, et läheb kiiremaks. …“
- beam 2: „… siis transskribing **rakenduse** jaoks …“ (beam parandab „akenduse“ → „rakenduse“, nagu Androidi TULEMUSED.md tekstis).
- f16, q8_0, q5_0, q4_0 andsid greedy-ga sama teksti; beam-iga erinesid ainult viimase poolelijäänud lause sabas.
- **Kinnitus RAPORT 3.2 p 2:** `-nt` (ajatemplid väljas) andis kõigil mudelitel kordusi ja prügi („globaid, tere“, „Arvo Loodame …“).
- Vaikus/lühike müra (`c_c.wav`, `c_d.wav` täisaknaga) → „Aitäh.“ – TextCleaner peab selle ära viskama.

## Täpsuse katsed päris salvestistega (2026-11-07)

Andmed: 5,5 min telefonikõne (Maci sisseehitatud mikrofon, teine pool telefoni kõlarist) ja 40 s ingliskeelne
YouTube kõlaritest. Tööriist: `Kirjuta --bench fail lang rt|win|vad …` (vt `Sources/Kirjuta/Bench.swift`).
Võrdlus: f16 + beam 5 VAD-rühmadega (pole päris tõde, ainult suunanäitaja) + teksti lugemine.

**Peamine leid: Maci mikrofoni heli on väga vaikne.** Kõne RMS oli ~40–200 (Android ~500+), aga Chunkeri
absoluutne kõnelävi oli 120. Seega peeti suur osa kõnest vaikuseks: laused lõigati pooleks ja jooksvat teksti
peaaegu ei tekkinud (pending() nõuab kõnet). Lävi Macis 40 (suhteline lävi müratase × 1,8 jääb).

| Reaalaeg (kõne) | tükke | WER vs viide | RTF |
|---|---|---|---|
| Android: paus 420 ms, 1,5–12 s, lävi 120 | 78 | 41,6 % | 0,18 |
| + beam 2 | 78 | 44,8 % | 0,18 |
| + täis audio_ctx | 78 | 41,1 % | 0,46 |
| + eelmine tekst promptiks | 78 | 48,1 % (jättis lõike vahele) | 0,17 |
| paus 800 ms, 3–15 s, lävi 40 (**uus**) | 44 | 36,5 % | 0,12 |

Pikem tükk = rohkem konteksti = täpsem; ooteaja katab jooksev (hall) tekst. YouTube: „twelve-wheel battery“ →
„twelve-volt battery“, „farm and safety“ → „fireman safety“.

**TÄPSUSTA:** pimesi 30 s aknad jätsid kõnes vahele (104–131 s kadus täiesti: vaikusega algav aken visati
whisperi no_speech-reegliga ära; üks 29 s lõik „Nii, mis sa täna veel?“ hüppas üle 28 s kõnest; aken algas keset
sõna → „The kind of HTTP. TheORTveis.“). Uus: VAD-kõnelõigud rühmitatakse ≤15 s akendeks (>3 s vaikus = uus
rühm), no_speech-reegel väljas, hõreda tulemuse korral lõigud ükshaaval. Puuduvad lõigud 5/64 → 0/64,
WER vs viide 43 % → 36 %, RTF ~0,2 (koos keeletuvastusega).

Tokenite eelarve loeb nüüd iga beam'i tokeneid eraldi (varem loendati filtri kutseid → beam 2 korral pool eelarvet).

## Kõnelejad (sherpa-onnx 2.0.1, pyannote int8 + wespeaker resnet34, sama mis Androidis)

Kiirus: 5,5 min kõne → 31 s (RTF 0,09, CPU 4 lõime). TÄPSUSTA koos kõnelejatega RTF ~0,32.

Automaatse kõnelejate arvu lävi (õige arv: kõne 2, johanna 2, s1 2, kirjuta-test 2, YouTube 1):

| lävi | kõne | johanna | s1 | kirjuta-test | YouTube |
|---|---|---|---|---|---|
| 0,8 (Android) | **5** | 2 | 2 | 2 | 1–2 |
| 0,9 | **3** | 2 | 2 | 2 | 1 |
| 1,0 | 2 | **1** | **1** | **1** | 1 |
| 0,9 + alla 8 % kõnest rühmad liidetakse lähimaga (**uus**) | 2 | 2 | 2 | 2 | 1 |

Kõnes oli üks hääl otse Maci mikrofonis ja teine telefoni kõlarist – sama inimese hääl jagunes 0,8 juures mitmeks.
3D-Speaker mudelid (campplus, eres2net) andsid samal lävel veel rohkem rühmi.

Kõneleja kaupa eraldi kirjutamine (iga aken ainult ühe kõneleja kõnega) andis lühikestele vastustele halvema
teksti („Kümmeacks“, „i--.“), seega kirjutatakse VAD-rühmade kaupa ja iga lause saab kõneleja, kelle hääl sellega
kõige rohkem kattub (Androidi `Diarizer.assign`).

# Ülesanne: dikteerimine Androidi äppi „Kirjuta Offline“ (sama mis Maci ⌥Space)

Kirjutatud Maci projektist (`~/kirjuta-mac`) Androidi projekti jaoks (`~/whisper-android/kirjuta-app`).
Maci teostus: `Sources/KirjutaCore/Engine/Dictation.swift` (loogika), `Sources/Kirjuta/Dictation.swift` (UI),
`Sources/Kirjuta/Typer.swift` (teksti sisestamine). Katsed ja põhjused: `TULEMUSED-MAC.md`.

## Mida kasutaja tahab

**Helitugevus üles + alla korraga** → dikteerimine algab ükskõik mis äpis (Messenger, WhatsApp, brauser …).
Tekst läheb **aktiivsesse tekstilahtrisse**, ekraanile tuleb väike indikaator (punane täpp + lainekuju + olek).
Sama kombinatsioon uuesti → lõpetab.

## Käitumine (täpselt nagu Macis – kasutaja on selle läbi proovinud ja heaks kiitnud)

1. Jooksev tekst (salvestamise „hall“ tekst) kirjutatakse lahtrisse kohe (~0,6 s tagant, ainult pooleli lause).
2. Kui lause lõpeb (paus), kirjutatakse see **täpsemalt üle** ja asendatakse lahtris.
3. Pärast iga lauset oodatakse **võlusõna**: `saada`, `send it` – **öeldud eraldi lausena** (pärast pausi).
   - võlusõna → kustutatakse lahtrist, **saadetakse** (Enter / saatmisnupp), lahter tühi, uus sõnum algab;
     seejärel **6 s** ootamist: kui selle ajaga uut **teksti** ei tule → dikteerimine lõpeb.
   - muud sõnad → eelmise lause lõppu punkt (kui pole .?!), tühik, jätkab samas sõnumis.
4. **Lõpusõna** `lõpeta`, `stop dictation` (eraldi) → kustutatakse lahtrist, lõpp **ilma saatmata**.
5. **30 s** ilma tuvastatud tekstita → lõpp.
6. Kõik seaded muudetavad: kiirklahv (kui võimalik), võlusõnad, lõpusõnad, ooteajad (6 s / 30 s),
   „salvesta dikteerimised ka salvestiste nimekirja“ (vaikimisi väljas).
7. Alati üks kõneleja – kõnelejate eristamist pole vaja. Salvestamise ajal dikteerida ei saa (ja vastupidi).

## Õppetunnid Macist (oluline – ära korda vigu)

- **Võlusõna äratundmine:** mudel kuuleb „saada“ peaaegu alati kui **„Sada.“**. Luba üks täheviga (≥5 tähte,
  Levenshtein ≤ 1) ja ühesõnaline käsk ka pöördes / ≤3-sõnalise lause viimase sõnana („ah ja lõpetage“,
  „lõpetaja“, „lõpetan“). Pikemad laused ei käivita („No okei saada seega“, „Ma tahan sulle pilti saada“,
  „Me lõpetasime kell üheksa …“). Testjuhtumid: `Sources/Kirjuta/SelfTest.swift` → `words()`.
- **Lühike tükk (<2 s):** ära tee keeletuvastust (kõigub inglise peale) – kasuta senist keelt; kui võlusõna ei
  leitud, proovi sama tükki ka teises keeles (en/et).
- Võlusõna võib olla ka tüki **viimane whisperi lõik** (kui paus jäi lühikeseks).
- **Chunker dikteerimiseks:** paus 700 ms, min 800 ms, max 15 s, **min kõne 200 ms** (Androidi 500 ms juures
  ei lõigatud lühikest „saada“ eraldi).
- **Taimerid (6 s / 30 s) nullib ainult tuvastatud tekst**, mitte energia-VAD „kõne“ – muidu hoiab taustamüra
  dikteerimist lõputult lahti.
- **Taustamüra korral** ei pruugi VAD pausi leida: kui jooksev tekst lõpeb võlu-/lõpusõnaga **kaks korda järjest**,
  lõika tükk kohe (flush) ja töötle.
- Lõpliku lause dekodeerimine: greedy, `audio_ctx = max(768, sek*50+400)` (≥1500 → 0), **temperature_inc 0.2**
  (ilma selleta hallutsinatsioonid muusika/müra korral), tokenite eelarve `sek*12+40`.
  Jooksev tekst: reaalaja seaded (greedy, `audio_ctx = max(640, sek*50+250)`, `temperature_inc 0`, eelarve `sek*10+30`).
- Lahtri uuendamine: hoia meeles, mis on lahtris selle sõnumi jooksul kirjutatud; muuda ainult erinevat lõppu.
- Logi iga lõplik lause (`Dict: lause 1.5 s [et]: Sada.`) – nii saab kasutaja logi põhjal viga leida.

## Androidi teostus (ettepanek – kontrolli Androidi versioonil / HyperOS-il)

- **AccessibilityService** (kasutaja lülitab sisse: Seaded → Lisaseaded → Hõlbustus → Kirjuta):
  - klahvid: `flagRequestFilterKeyEvents` + `onKeyEvent` – üles+alla vajutatud ~300 ms jooksul → toggle
    (ja need sündmused „neela“, et helitugevus ei muutuks). Töötab avatud ekraaniga. Alternatiiv/varu:
    Androidi sisseehitatud **hõlbustuse otsetee** (mõlemad helitugevuse klahvid 3 s all) saab käivitada sama teenuse.
  - teksti sisestamine: fookuses olev `AccessibilityNodeInfo` (`findFocus(FOCUS_INPUT)`) →
    `ACTION_SET_TEXT` (lahtri olemasolev tekst + dikteeritud tekst; jooksva teksti asendamine on nii lihtne).
    Mõni äpp ei luba SET_TEXT-i → varu: lõikelaud + `ACTION_PASTE`.
  - saatmine: Enter ei ole Androidis universaalne. Proovi: `ACTION_IME_ENTER` (API 30+), muidu otsi ekraanilt
    saatmisnupp (contentDescription „Send“/„Saada“/„Saatke“, nt WhatsApp/Messenger) ja `ACTION_CLICK`.
  - indikaator: `TYPE_ACCESSIBILITY_OVERLAY` aken (eraldi luba pole vaja), ei võta fookust.
- **Mikrofon:** foreground service tüübiga `microphone` (manifestis juba `FOREGROUND_SERVICE_MICROPHONE`).
  Kontrolli, et teenust tohib taustalt käivitada (hõlbustusteenusega äpp on Android 14+ erandite seas – testi).
  Xiaomi/HyperOS: autostart + aku „Pole piiranguid“, muidu tapetakse.
- Mudel ja mootor: sama mis salvestamisel (`engine/Engine.kt`, q4_0 telefonis), sama `TextCleaner`.
  Dikteerimise loogika (ülal) on puhas Kotlin-klass – porti Maci `DictationEngine` (≈300 rida).

## Testimine

- Peata test helifailiga (Macis `--dictate fail.wav`, `--words`): sisend → lahtri sisu muutused, saatmised, lõpp.
- Sünteetiline: `say -v Samantha -o send.aiff "Send it."` + lause + vaikused/müra (vt Maci `TULEMUSED-MAC.md`).
- Telefonis: Messenger/WhatsApp – lause → paus → „saada“ → 6 s → lõpp; „lõpeta“; taustamüraga.

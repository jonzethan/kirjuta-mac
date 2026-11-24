# Kirjuta (Mac)

Eesti ja inglise kõne tekstiks **täiesti võrguühenduseta** – TalTechi Whisperi mudel jookseb Maci graafikaprotsessoril
(whisper.cpp + Metal). Androidi äpi **Kirjuta Offline** Maci versioon.

- **Salvesta** koosolek või kõne (⌘R): tekst tuleb jooksvalt, pärast kirjutatakse kõik täpsemalt üle ja **kõnelejad
  eristatakse** hääle järgi.
- **Helifail** (mp3, m4a, wav, video …): lohista aknasse.
- **Dikteeri** suvalisse tekstilahtrisse (⌥Space): räägi, tekst ilmub lahtrisse; eraldi öeldud **„saada“** vajutab Enter,
  **„lõpeta“** lõpetab.
- Keel (eesti/inglise) tuvastatakse automaatselt. Eksport: TXT, Markdown, SRT, VTT, heli.
- Salvestised: `~/Kirjuta/sessions` (sama vorming mis Androidi äpis, vt [SESSION_FORMAT.md](SESSION_FORMAT.md)).

Nõuded: **Apple Silicon** (M1 või uuem), **macOS 14.2+**, soovitatavalt 16 GB mälu (8 GB töötab).

## Paigaldamine

1. Lae [Releases](../../releases) lehelt üks kahest, ava see ja lohista **Kirjuta** kausta **Applications**:
   - `Kirjuta-….dmg` (~850 MB) – **koos mudeliga**, töötab kohe (punkt 3 jääb vahele);
   - `Kirjuta-…-ilma-mudeliteta.dmg` (~10 MB) – ainult äpp, mudelid lae ise (punkt 3).
2. Esimene avamine: **paremklõps → Ava → Ava** (äpp on allkirjastatud isetehtud sertifikaadiga, mitte Apple'i omaga;
   kui „Ava“ nuppu pole: Süsteemiseaded → Privaatsus ja turvalisus → „Ava ikkagi“).
3. (Ainult „ilma-mudeliteta“ puhul) pane mudelid kausta `~/Kirjuta/models` (vt allpool) ja käivita Kirjuta uuesti.
4. Luba **mikrofon**; dikteerimiseks ka **Süsteemiseaded → Privaatsus ja turvalisus → Hõlbustus → Kirjuta**.

## Mudelid

Äpp ise internetti ei kasuta – mudelid tuleb üks kord alla laadida. Kõige lihtsam (Terminalis):

```sh
curl -fsSL https://raw.githubusercontent.com/jonzethan/kirjuta-mac/master/scripts/download-models.sh | zsh
```

…või käsitsi. Kaustade struktuur:

```
~/Kirjuta/models/
├── taltech-et-turbo-f16.bin                     ← keelemudel (kohustuslik)
└── diar/                                        ← kõnelejate eristamine (soovitatav)
    ├── sherpa-onnx-pyannote-segmentation-3-0/
    │   └── model.int8.onnx
    └── wespeaker_en_voxceleb_resnet34_LM.onnx
```

| Fail | Allikas | Suurus |
|---|---|---|
| `taltech-et-turbo-f16.bin` | TalTech [whisper-large-v3-turbo-et-verbatim-2604] → [ggml/ggml-model.bin][ggml] (nimeta ümber või jäta `ggml-model.bin`) | 1,6 GB |
| `diar/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx` | [sherpa-onnx-pyannote-segmentation-3-0.tar.bz2][seg] (arhiivist) | 1,5 MB |
| `diar/wespeaker_en_voxceleb_resnet34_LM.onnx` | [wespeaker_en_voxceleb_resnet34_LM.onnx][emb] | 27 MB |

Valikuline: väiksem `taltech-et-turbo-q8_0.bin` (874 MB, sama kvaliteet) – tee f16-st whisper.cpp tööriistaga
`whisper-quantize taltech-et-turbo-f16.bin taltech-et-turbo-q8_0.bin q8_0` (skript teeb selle ise, kui projekt on
ehitatud). Kui mõlemad on olemas, saab mudeli valida seadetes (⌘,).

Ilma `diar` kaustata töötab kõik peale kõnelejate eristamise.

[whisper-large-v3-turbo-et-verbatim-2604]: https://huggingface.co/TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604
[ggml]: https://huggingface.co/TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604/resolve/main/ggml/ggml-model.bin
[seg]: https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
[emb]: https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx

## Kasutamine

| | |
|---|---|
| ⌘R | salvesta / lõpeta (pärast lõppu täpsustab automaatselt) |
| ⌥Space | dikteeri aktiivsesse lahtrisse (muudetav: Seaded → Dikteerimine) |
| „saada“ / „send it“ | eraldi öeldes: Enter (sõnum teele); 6 s vaikust → dikteerimine lõpeb |
| „lõpeta“ / „stop dictation“ | lõpetab dikteerimise ilma saatmata |
| ⌘T | täpsusta valitud salvestis |
| KÕNELEJAD ▾ | jaga kõnelejad uuesti (automaatne või täpne arv) |
| ⌘E, ⇧⌘C | ekspordi tekst, kopeeri tekst |

Menüüribal on Kirjuta ikoon (ring ja täpp); akna sulgemisel jääb äpp sinna ja kiirklahv töötab edasi.

## Ehitamine lähtekoodist

```sh
git clone --recursive https://github.com/jonzethan/kirjuta-mac && cd kirjuta-mac
scripts/build-whisper.sh      # whisper.cpp (commit 482279b) Metaliga
scripts/fetch-sherpa.sh       # sherpa-onnx 2.0.1 staatilised teegid
scripts/make-cert.sh          # püsiv allkirjastamise sertifikaat (load ei kao iga ehitusega)
scripts/make-app.sh           # build/Kirjuta.app
scripts/make-dmg.sh [--no-models]
```

Vaja: Xcode või Command Line Tools (Swift 6), CMake. Mõõtmised ja katsed: [TULEMUSED-MAC.md](TULEMUSED-MAC.md).

## Litsentsid

Keelemudel: [TalTechNLP](https://huggingface.co/TalTechNLP) (vt mudeli lehte). Kõnetuvastus: [whisper.cpp] (MIT).
Kõnelejad: [sherpa-onnx] (Apache-2.0), pyannote segmentation 3.0 (MIT), WeSpeaker.

[whisper.cpp]: https://github.com/ggml-org/whisper.cpp
[sherpa-onnx]: https://github.com/k2-fsa/sherpa-onnx

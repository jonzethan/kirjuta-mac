# Salvestise kaustavorming (ühine Androidi „Kirjuta Offline“ äpiga)

Macis: `~/Kirjuta/sessions/<id>/`, kus `<id>` = `yyyyMMdd-HHmmss` (salvestuse algus, kohalik aeg) – sama mis Androidis.
Telefoni kausta võib kopeerida otse `~/Kirjuta/sessions/` alla ja vastupidi.

| Fail | Sisu | Android | Mac |
|---|---|---|---|
| `audio.wav` | 16 kHz mono 16-bit PCM. Päist uuendatakse iga 5 s; katkenud fail parandatakse avamisel (`WavWriter.repair`). | ✔ | ✔ (etapp 2: mikrofon; etapp 3+: mic+süsteem kokku miksitud kuulamiseks) |
| `mic.wav` | ainult mikrofon (Mina), sama formaat | – | etapp 3+ |
| `system.wav` | ainult süsteemiheli (Nemad), sama formaat | – | etapp 3+ |
| `segments.tsv` | üks rida lõigu kohta: `algus_ms \t lõpp_ms \t tekst [\t kõneleja_nr]`; ajad sessiooni algusest | ✔ | ✔ |
| `segments.live.tsv` | reaalaja-tekst pärast TÄPSUSTA't | ✔ | etapp 5 |
| `lang` | `et` või `en` | ✔ | ✔ |
| `title` | pealkiri (imporditud failid) | ✔ | etapp 5 |
| `speakers.txt` | kõnelejate nimed ridadena `nr=Nimi` | ✔ | ✔ |
| `pinned` | olemas = üles kinnitatud | ✔ | etapp 4 |

## Mina / Nemad
- Kõneleja number tuleb voost: **0 = mikrofon**, **1 = süsteemiheli**. Mac kirjutab `speakers.txt`-i `0=Mina` ja `1=Nemad`.
  Android näitab neid tavaliste kõnelejanimedena, seega telefon ei katke.
- Kui süsteemiheli voole tehakse hiljem kõnelejate eristus (etapp 6), saavad sealsed kõnelejad numbrid alates 1
  (`1=Nemad`/`1=Kõneleja A`, `2=…`); 0 jääb alati „Mina“ jaoks.
- Rida ilma 4. veeruta = kõneleja määramata (vanad/Androidi salvestised).

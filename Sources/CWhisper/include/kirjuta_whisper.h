// Õhuke C-kiht whisper.cpp ümber (port Androidi cpp/jni.c-st). Swift näeb ainult neid funktsioone.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Laeb mudeli. use_gpu = Metal, flash_attn = kiire tähelepanu. NULL = viga.
void *kw_init(const char *model_path, bool use_gpu, bool flash_attn);
void kw_free(void *ctx);

/// Transkribeerib 16 kHz mono float heli. Tagastab malloc'itud UTF-8 teksti kujul
/// "t0_ms\tt1_ms\ttekst\n" iga lõigu kohta (vabasta kw_free_str-iga) või NULL vea korral.
/// beam > 1 = beam search; single_pass = lubab ainult ühe kodeerija käivituse (TÄPSUSTA).
/// max_tokens > 0: kogu tüki tokenite eelarve (kordamise piir) – pärast seda sunnitakse tekst lõppema.
char *kw_transcribe(void *ctx, const float *samples, int n_samples, int threads, int audio_ctx,
                    const char *lang, int beam, bool single_pass, int max_tokens, const char *prompt, float no_speech_thold, float temp_inc);

/// Keeletuvastus ainult eesti ja inglise vahel (eraldi whisperi olek, lühike 12,8 s kodeerija aken).
/// Kirjutab tõenäosused p_et, p_en (kogu keelte jaotusest). 0 = OK.
int kw_detect_et_en(void *ctx, const float *samples, int n_samples, int threads, float *p_et, float *p_en);
void kw_free_str(char *s);

const char *kw_system_info(void);
/// true = whisper.cpp/ggml logi vaigistatakse (ainult vead jäävad).
void kw_quiet_logs(bool quiet);

#ifdef __cplusplus
}
#endif

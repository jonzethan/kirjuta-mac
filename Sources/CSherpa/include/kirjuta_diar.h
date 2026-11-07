#pragma once
#include <stdint.h>

// Kõnelejate eristamine (sherpa-onnx: pyannote segmenteerimine + hääle-sõrmejälg + rühmitamine).
typedef struct { float start, end; int32_t speaker; } kd_turn;

// num_speakers > 0 = täpne arv, muidu automaatne (threshold). Tagastab NULL, kui mudeleid ei saa laadida.
void *kd_create(const char *seg_model, const char *emb_model, int32_t num_speakers, float threshold, int32_t threads);
void kd_free(void *sd);
// Tagastab pöörete arvu (*out vabasta kd_free_turns-iga) või < 0 vea korral.
// progress(done, total, arg) – tagasta 0, et jätkata.
int32_t kd_process(void *sd, const float *samples, int32_t n, kd_turn **out,
                   int32_t (*progress)(int32_t, int32_t, void *), void *arg);
void kd_free_turns(kd_turn *t);

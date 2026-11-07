#include "kirjuta_whisper.h"
#include "whisper.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Lubab ainult ühe kodeerija käivituse. Muidu teeb whisper.cpp tüki lõpuosa (mida mudel ei
// kirjutanud) jaoks uue täis 30 s akna (~2x aeg); TÄPSUSTA liidab selle osa järgmise aknaga.
static bool only_first_encode(struct whisper_context *ctx, struct whisper_state *state, void *user_data) {
    (void) ctx; (void) state;
    int *n = (int *) user_data;
    return (*n)++ == 0;
}

static bool g_quiet = false;
static void log_cb(enum ggml_log_level level, const char *text, void *user_data) {
    (void) user_data;
    if (g_quiet && level != GGML_LOG_LEVEL_ERROR) return;
    fputs(text, stderr);
}

void kw_quiet_logs(bool quiet) {
    g_quiet = quiet;
    whisper_log_set(log_cb, NULL);
}

void *kw_init(const char *model_path, bool use_gpu) {
    struct whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = use_gpu;
    cp.flash_attn = true;
    return whisper_init_from_file_with_params(model_path, cp);
}

void kw_free(void *ctx) {
    if (ctx) whisper_free((struct whisper_context *) ctx);
}

void kw_free_str(char *s) { free(s); }

const char *kw_system_info(void) { return whisper_print_system_info(); }

char *kw_transcribe(void *vctx, const float *samples, int n_samples, int threads, int audio_ctx,
                    const char *lang, int beam, bool single_pass) {
    struct whisper_context *ctx = (struct whisper_context *) vctx;
    if (!ctx) return NULL;

    struct whisper_full_params p = whisper_full_default_params(beam > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
    if (beam > 1) {
        p.beam_search.beam_size = beam;
        p.greedy.best_of = beam;
    }
    p.n_threads = threads;
    p.language = lang;
    p.translate = false;
    p.no_context = true;
    p.no_timestamps = false;     // ajatemplid PEAVAD olema sees, muidu mudel kordab
    p.temperature_inc = 0.0f;    // ilma temperatuuri-kordusteta: ennustatav kiirus
    p.single_segment = false;
    p.print_realtime = false;
    p.print_progress = false;
    p.print_timestamps = false;
    p.print_special = false;
    p.suppress_blank = true;
    p.audio_ctx = audio_ctx;
    int encodes = 0;
    if (single_pass) {
        p.encoder_begin_callback = only_first_encode;
        p.encoder_begin_callback_user_data = &encodes;
    }

    if (whisper_full(ctx, p, samples, n_samples) != 0) return NULL;

    size_t cap = 1024, len = 0;
    char *buf = malloc(cap);
    const int ns = whisper_full_n_segments(ctx);
    for (int i = 0; i < ns; i++) {
        char head[48];
        const int hl = snprintf(head, sizeof(head), "%lld\t%lld\t",
                                (long long) whisper_full_get_segment_t0(ctx, i) * 10,
                                (long long) whisper_full_get_segment_t1(ctx, i) * 10);
        const char *t = whisper_full_get_segment_text(ctx, i);
        const size_t need = len + strlen(t) + hl + 2;
        if (need > cap) {
            while (need > cap) cap *= 2;
            buf = realloc(buf, cap);
        }
        memcpy(buf + len, head, hl);
        len += hl;
        for (const char *c = t; *c; c++) buf[len++] = (*c == '\n' || *c == '\t') ? ' ' : *c;
        buf[len++] = '\n';
    }
    buf[len] = 0;
    return buf;
}

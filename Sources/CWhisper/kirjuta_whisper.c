#include "kirjuta_whisper.h"
#include "whisper.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

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

// Kontekst + eraldi olek keeletuvastuseks (selle exp_n_audio_ctx on 640, et tuvastus oleks kiire).
struct kw_ctx {
    struct whisper_context *ctx;
    struct whisper_state *dstate;
};

struct token_budget {
    int calls;
    int budget;
};

// Kordamise piir: kui tokeneid on eelarvest rohkem, luba ainult teksti lõpp (EOT).
static void budget_filter(struct whisper_context *ctx, struct whisper_state *state,
                          const whisper_token_data *tokens, int n_tokens, float *logits, void *user_data) {
    (void) state; (void) tokens; (void) n_tokens;
    struct token_budget *b = (struct token_budget *) user_data;
    if (++b->calls <= b->budget) return;
    const int eot = whisper_token_eot(ctx);
    const int nv = whisper_n_vocab(ctx);
    for (int i = 0; i < nv; i++) if (i != eot) logits[i] = -INFINITY;
}

void kw_quiet_logs(bool quiet) {
    g_quiet = quiet;
    whisper_log_set(log_cb, NULL);
}

void *kw_init(const char *model_path, bool use_gpu) {
    struct whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = use_gpu;
    cp.flash_attn = true;
    struct whisper_context *c = whisper_init_from_file_with_params(model_path, cp);
    if (!c) return NULL;
    struct kw_ctx *k = calloc(1, sizeof(struct kw_ctx));
    k->ctx = c;
    return k;
}

void kw_free(void *vk) {
    struct kw_ctx *k = (struct kw_ctx *) vk;
    if (!k) return;
    if (k->dstate) whisper_free_state(k->dstate);
    whisper_free(k->ctx);
    free(k);
}

static struct whisper_full_params base_params(int threads, const char *lang) {
    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = threads;
    p.language = lang;
    p.no_context = true;
    p.no_timestamps = false;
    p.temperature_inc = 0.0f;
    p.print_realtime = false;
    p.print_progress = false;
    p.print_timestamps = false;
    p.print_special = false;
    p.suppress_blank = true;
    return p;
}

int kw_detect_et_en(void *vk, const float *samples, int n_samples, int threads, float *p_et, float *p_en) {
    struct kw_ctx *k = (struct kw_ctx *) vk;
    if (!k || n_samples <= 0) return -1;
    if (!k->dstate) {
        k->dstate = whisper_init_state(k->ctx);
        if (!k->dstate) return -2;
        // whisper_full seab oleku kodeerija akna (audio_ctx); tuvastus kasutab seda edaspidi
        struct whisper_full_params p = base_params(threads, "et");
        p.audio_ctx = 640;
        float zeros[16000] = {0};
        whisper_full_with_state(k->ctx, k->dstate, p, zeros, 16000);
    }
    const int n = n_samples > 16000 * 12 ? 16000 * 12 : n_samples;
    if (whisper_pcm_to_mel_with_state(k->ctx, k->dstate, samples, n, threads) != 0) return -3;
    const int nl = whisper_lang_max_id() + 1;
    float *probs = calloc(nl, sizeof(float));
    const int id = whisper_lang_auto_detect_with_state(k->ctx, k->dstate, 0, threads, probs);
    if (id >= 0) {
        *p_et = probs[whisper_lang_id("et")];
        *p_en = probs[whisper_lang_id("en")];
    }
    free(probs);
    return id >= 0 ? 0 : -4;
}

void kw_free_str(char *s) { free(s); }

const char *kw_system_info(void) { return whisper_print_system_info(); }

char *kw_transcribe(void *vk, const float *samples, int n_samples, int threads, int audio_ctx,
                    const char *lang, int beam, bool single_pass, int max_tokens) {
    struct kw_ctx *k = (struct kw_ctx *) vk;
    if (!k) return NULL;
    struct whisper_context *ctx = k->ctx;

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

    struct token_budget budget = { 0, max_tokens };
    if (max_tokens > 0) {
        p.logits_filter_callback = budget_filter;
        p.logits_filter_callback_user_data = &budget;
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

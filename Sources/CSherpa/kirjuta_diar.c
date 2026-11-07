#include "kirjuta_diar.h"
#include "sherpa-onnx/c-api/c-api.h"
#include <stdlib.h>
#include <string.h>

void *kd_create(const char *seg_model, const char *emb_model, int32_t num_speakers, float threshold, int32_t threads) {
    SherpaOnnxOfflineSpeakerDiarizationConfig c;
    memset(&c, 0, sizeof(c));
    c.segmentation.pyannote.model = seg_model;
    c.segmentation.pyannote.window_shift_ratio = 0;   // vaikimisi 0.1
    c.segmentation.num_threads = threads;
    c.segmentation.provider = "cpu";
    c.embedding.model = emb_model;
    c.embedding.num_threads = threads;
    c.embedding.provider = "cpu";
    c.clustering.num_clusters = num_speakers > 0 ? num_speakers : -1;
    c.clustering.threshold = threshold;
    c.min_duration_on = 0.3f;
    c.min_duration_off = 0.5f;
    return (void *) SherpaOnnxCreateOfflineSpeakerDiarization(&c);
}

void kd_free(void *sd) {
    if (sd) SherpaOnnxDestroyOfflineSpeakerDiarization((const SherpaOnnxOfflineSpeakerDiarization *) sd);
}

int32_t kd_process(void *sd, const float *samples, int32_t n, kd_turn **out,
                   int32_t (*progress)(int32_t, int32_t, void *), void *arg) {
    *out = NULL;
    if (!sd) return -1;
    const SherpaOnnxOfflineSpeakerDiarizationResult *r = progress
        ? SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(sd, samples, n, progress, arg)
        : SherpaOnnxOfflineSpeakerDiarizationProcess(sd, samples, n);
    if (!r) return -2;
    const int32_t ns = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(r);
    const SherpaOnnxOfflineSpeakerDiarizationSegment *s = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(r);
    kd_turn *t = calloc(ns > 0 ? ns : 1, sizeof(kd_turn));
    for (int32_t i = 0; i < ns && s; i++) { t[i].start = s[i].start; t[i].end = s[i].end; t[i].speaker = s[i].speaker; }
    if (s) SherpaOnnxOfflineSpeakerDiarizationDestroySegment(s);
    SherpaOnnxOfflineSpeakerDiarizationDestroyResult(r);
    *out = t;
    return ns;
}

void kd_free_turns(kd_turn *t) { free(t); }

void *kd_emb_create(const char *model, int32_t threads) {
    SherpaOnnxSpeakerEmbeddingExtractorConfig c;
    memset(&c, 0, sizeof(c));
    c.model = model;
    c.num_threads = threads;
    c.provider = "cpu";
    return (void *) SherpaOnnxCreateSpeakerEmbeddingExtractor(&c);
}

void kd_emb_free(void *e) {
    if (e) SherpaOnnxDestroySpeakerEmbeddingExtractor((const SherpaOnnxSpeakerEmbeddingExtractor *) e);
}

int32_t kd_emb_dim(void *e) { return SherpaOnnxSpeakerEmbeddingExtractorDim((const SherpaOnnxSpeakerEmbeddingExtractor *) e); }

int32_t kd_emb_compute(void *ve, const float *samples, int32_t n, float *out) {
    const SherpaOnnxSpeakerEmbeddingExtractor *e = (const SherpaOnnxSpeakerEmbeddingExtractor *) ve;
    const SherpaOnnxOnlineStream *s = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(e);
    if (!s) return -1;
    SherpaOnnxOnlineStreamAcceptWaveform(s, 16000, samples, n);
    SherpaOnnxOnlineStreamInputFinished(s);
    int32_t rc = -2;
    if (SherpaOnnxSpeakerEmbeddingExtractorIsReady(e, s)) {
        const float *v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(e, s);
        if (v) {
            memcpy(out, v, sizeof(float) * SherpaOnnxSpeakerEmbeddingExtractorDim(e));
            SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v);
            rc = 0;
        }
    }
    SherpaOnnxDestroyOnlineStream(s);
    return rc;
}

/**
 * Thin C bridge for NSFW detection using ONNX Runtime.
 *
 * Exposes simple functions for Dart FFI:
 *   nsfw_init()     — load both ONNX models
 *   nsfw_classify() — run two-stage NSFW pipeline on preprocessed image data
 *   nsfw_free()     — release all resources
 *
 * Compile:
 *   gcc -shared -fPIC -O2 -o libnsfw_bridge.so nsfw_bridge.c \
 *       -I/path/to/onnxruntime/include -L/path/to/onnxruntime/lib -lonnxruntime
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "onnxruntime_c_api.h"

/* ── Result struct (matches Dart FFI) ── */

typedef struct {
    float nsfw_score;      /* pre-filter NSFW probability (stage 1) */
    float safe_score;      /* stage 2 safe probability */
    float questionable;    /* stage 2 questionable probability */
    float unsafe_score;    /* stage 2 unsafe probability */
    int   stage;           /* 0=error, 1=prefilter_pass, 2=confirmed,
                              3=overridden, 4=prefilter_strong, 5=prefilter_only */
} NsfwResult;

/* ── Handle struct ── */

struct NsfwHandle {
    const OrtApi*       api;
    OrtEnv*             env;
    OrtSessionOptions*  opts;
    OrtSession*         prefilter;
    OrtSession*         confirm;
    OrtMemoryInfo*      mem_info;
};

/* ── Softmax helper ── */

static void softmax(const float* logits, float* probs, int n) {
    float max_val = logits[0];
    for (int i = 1; i < n; i++)
        if (logits[i] > max_val) max_val = logits[i];
    float sum = 0.0f;
    for (int i = 0; i < n; i++) {
        probs[i] = expf(logits[i] - max_val);
        sum += probs[i];
    }
    for (int i = 0; i < n; i++)
        probs[i] /= sum;
}

/* Forward declarations */
typedef struct NsfwHandle NsfwHandle;
void nsfw_free(NsfwHandle* h);

/* ── Public API ── */

/**
 * Initialize NSFW detector with paths to both ONNX model files.
 * confirm_path may be NULL to use pre-filter only mode.
 * Returns opaque handle, or NULL on failure.
 */
NsfwHandle* nsfw_init(const char* prefilter_path, const char* confirm_path) {
    NsfwHandle* h = (NsfwHandle*)calloc(1, sizeof(NsfwHandle));
    if (!h) return NULL;

    h->api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!h->api) { free(h); return NULL; }

    OrtStatus* s;

    s = h->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "nsfw", &h->env);
    if (s) { h->api->ReleaseStatus(s); free(h); return NULL; }

    s = h->api->CreateSessionOptions(&h->opts);
    if (s) { h->api->ReleaseStatus(s); h->api->ReleaseEnv(h->env); free(h); return NULL; }

    h->api->SetIntraOpNumThreads(h->opts, 2);
    h->api->SetSessionGraphOptimizationLevel(h->opts, ORT_ENABLE_ALL);

    /* Load pre-filter model */
    s = h->api->CreateSession(h->env, prefilter_path, h->opts, &h->prefilter);
    if (s) {
        fprintf(stderr, "[nsfw_bridge] Failed to load prefilter: %s\n",
                h->api->GetErrorMessage(s));
        h->api->ReleaseStatus(s);
        h->api->ReleaseSessionOptions(h->opts);
        h->api->ReleaseEnv(h->env);
        free(h);
        return NULL;
    }

    /* Load confirmation model (optional) */
    if (confirm_path) {
        s = h->api->CreateSession(h->env, confirm_path, h->opts, &h->confirm);
        if (s) {
            fprintf(stderr, "[nsfw_bridge] Warning: confirmation model not loaded: %s\n",
                    h->api->GetErrorMessage(s));
            h->api->ReleaseStatus(s);
            h->confirm = NULL; /* proceed with prefilter only */
        }
    }

    s = h->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &h->mem_info);
    if (s) {
        h->api->ReleaseStatus(s);
        nsfw_free(h);
        return NULL;
    }

    return h;
}

/**
 * Run the two-stage NSFW classification on preprocessed image data.
 *
 * For the pre-filter (384x384): pass CHW float data with ViT normalization.
 * For the confirmation (224x224): pass CHW float data with ImageNet normalization.
 *
 * The caller must preprocess images in Dart and pass both buffers.
 *
 * prefilter_data: float[1][3][384][384] — ViT-normalized CHW
 * confirm_data:   float[1][3][224][224] — ImageNet-normalized CHW (may be NULL)
 */
NsfwResult nsfw_classify(NsfwHandle* h,
                         const float* prefilter_data,
                         const float* confirm_data) {
    NsfwResult result = {0.0f, 0.0f, 0.0f, 0.0f, 0};
    if (!h || !h->api || !prefilter_data) return result;

    OrtStatus* s;

    /* ── Stage 1: Pre-filter (384x384) ── */
    int64_t pf_shape[] = {1, 3, 384, 384};
    size_t pf_size = 1 * 3 * 384 * 384 * sizeof(float);
    OrtValue* pf_input = NULL;
    s = h->api->CreateTensorWithDataAsOrtValue(
        h->mem_info, (void*)prefilter_data, pf_size,
        pf_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &pf_input);
    if (s) { h->api->ReleaseStatus(s); return result; }

    const char* pf_input_names[]  = {"input"};
    const char* pf_output_names[] = {"output"};
    OrtValue* pf_output = NULL;

    s = h->api->Run(h->prefilter, NULL,
                     pf_input_names, (const OrtValue* const*)&pf_input, 1,
                     pf_output_names, 1, &pf_output);
    h->api->ReleaseValue(pf_input);
    if (s) { h->api->ReleaseStatus(s); return result; }

    float* pf_logits = NULL;
    h->api->GetTensorMutableData(pf_output, (void**)&pf_logits);

    float pf_probs[2];
    softmax(pf_logits, pf_probs, 2);
    h->api->ReleaseValue(pf_output);

    /* Marqo labels: 0=NSFW, 1=SFW */
    result.nsfw_score = pf_probs[0];

    /* Pre-filter < 0.5 → safe, skip stage 2 */
    if (pf_probs[0] < 0.5f) {
        result.safe_score = pf_probs[1];
        result.stage = 1; /* prefilter_pass */
        return result;
    }

    /* ── Stage 2: Confirmation (224x224) ── */
    if (!h->confirm || !confirm_data) {
        /* No confirmation model — trust prefilter at high threshold */
        result.safe_score = pf_probs[1];
        result.stage = (pf_probs[0] >= 0.93f) ? 5 : 0; /* prefilter_only or uncertain */
        return result;
    }

    int64_t cf_shape[] = {1, 3, 224, 224};
    size_t cf_size = 1 * 3 * 224 * 224 * sizeof(float);
    OrtValue* cf_input = NULL;
    s = h->api->CreateTensorWithDataAsOrtValue(
        h->mem_info, (void*)confirm_data, cf_size,
        cf_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &cf_input);
    if (s) { h->api->ReleaseStatus(s); h->api->ReleaseValue(cf_input); return result; }

    const char* cf_input_names[]  = {"pixel_values"};
    const char* cf_output_names[] = {"logits"};
    OrtValue* cf_output = NULL;

    s = h->api->Run(h->confirm, NULL,
                     cf_input_names, (const OrtValue* const*)&cf_input, 1,
                     cf_output_names, 1, &cf_output);
    h->api->ReleaseValue(cf_input);
    if (s) { h->api->ReleaseStatus(s); return result; }

    float* cf_logits = NULL;
    h->api->GetTensorMutableData(cf_output, (void**)&cf_logits);

    /* FocalNet: 5 classes [drawings, hentai, neutral, porn, sexy] */
    float cf_probs[5];
    softmax(cf_logits, cf_probs, 5);
    h->api->ReleaseValue(cf_output);

    result.safe_score    = cf_probs[0] + cf_probs[2]; /* drawings + neutral */
    result.questionable  = cf_probs[4];                /* sexy */
    result.unsafe_score  = cf_probs[1] + cf_probs[3];  /* hentai + porn */


    float combined = result.questionable + result.unsafe_score;

    if (result.unsafe_score >= 0.15f || combined >= 0.25f) {
        result.stage = 2; /* confirmed */
    } else if (pf_probs[0] >= 0.93f) {
        /* Prefilter very confident (≥93%). FocalNet has a known blind spot for
           drawn/anthropomorphic NSFW (classifies as "neutral" or "drawings").
           Trust the prefilter at this confidence level. */
        result.stage = 4; /* prefilter_strong */
    } else {
        result.stage = 3; /* overridden — prefilter flagged but confirmation disagrees */
    }

    return result;
}

/**
 * Release all ONNX Runtime resources.
 */
void nsfw_free(NsfwHandle* h) {
    if (!h) return;
    if (h->mem_info)  h->api->ReleaseMemoryInfo(h->mem_info);
    if (h->confirm)   h->api->ReleaseSession(h->confirm);
    if (h->prefilter) h->api->ReleaseSession(h->prefilter);
    if (h->opts)      h->api->ReleaseSessionOptions(h->opts);
    if (h->env)       h->api->ReleaseEnv(h->env);
    free(h);
}

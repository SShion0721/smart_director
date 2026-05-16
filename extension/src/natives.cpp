#include "extension.h"
#include "score_service.h"

#include <cstdint>
#include <cstring>

namespace {
cell_t float_to_cell(float value) {
    static_assert(sizeof(cell_t) == sizeof(float), "SourcePawn cells must be 32-bit");
    cell_t cell = 0;
    std::memcpy(&cell, &value, sizeof(value));
    return cell;
}

cell_t Native_LoadModel(IPluginContext* context, const cell_t* params) {
    char* path = nullptr;
    if (context->LocalToString(params[1], &path) != SP_ERROR_NONE || !path)
        return context->ThrowNativeError("invalid model path");
    return g_ScoreService.load_model(path) ? 1 : 0;
}

cell_t Native_IsReady(IPluginContext*, const cell_t*) {
    return g_ScoreService.ready() ? 1 : 0;
}

cell_t Native_GetInputDim(IPluginContext*, const cell_t*) {
    return g_ScoreService.input_dim();
}

cell_t Native_GetHiddenDim(IPluginContext*, const cell_t*) {
    return g_ScoreService.hidden_dim();
}

cell_t Native_GetMidDim(IPluginContext*, const cell_t*) {
    return g_ScoreService.mid_dim();
}

cell_t Native_ConfigureCache(IPluginContext* context, const cell_t* params) {
    const int megabytes = params[1];
    if (megabytes < 1 || megabytes > 1024)
        return context->ThrowNativeError("cache size must be in [1, 1024] MiB");
    return g_ScoreService.configure_cache(megabytes) ? 1 : 0;
}

cell_t Native_ClearCache(IPluginContext*, const cell_t*) {
    g_ScoreService.clear_cache();
    return 0;
}

cell_t Native_ScoreBatch(IPluginContext* context, const cell_t* params) {
    cell_t* shared = nullptr;
    cell_t* candidates = nullptr;
    cell_t* output = nullptr;

    if (context->LocalToPhysAddr(params[1], &shared) != SP_ERROR_NONE
        || context->LocalToPhysAddr(params[2], &candidates) != SP_ERROR_NONE
        || context->LocalToPhysAddr(params[5], &output) != SP_ERROR_NONE) {
        return context->ThrowNativeError("invalid SourcePawn array address");
    }

    const int candidate_count = params[3];
    const int words_per_candidate = params[4];
    const int score_capacity = params[6];

    if (candidate_count <= 0 || candidate_count > 512)
        return context->ThrowNativeError("candidate_count must be in [1, 512]");
    if (words_per_candidate != 4)
        return context->ThrowNativeError("words_per_candidate must be 4");
    if (score_capacity < candidate_count)
        return context->ThrowNativeError("score buffer is too small");

    std::uint32_t shared_words[4];
    for (int i = 0; i < 4; ++i)
        shared_words[i] = static_cast<std::uint32_t>(shared[i]);

    float scores[512];
    const int written = g_ScoreService.score_batch(
        shared_words,
        reinterpret_cast<const std::uint32_t*>(candidates),
        candidate_count,
        words_per_candidate,
        scores,
        score_capacity);

    if (written <= 0) return 0;

    for (int i = 0; i < written; ++i)
        output[i] = float_to_cell(scores[i]);
    return written;
}

cell_t Native_GetStats(IPluginContext* context, const cell_t* params) {
    cell_t* hits = nullptr;
    cell_t* misses = nullptr;
    cell_t* dedup = nullptr;
    cell_t* batches = nullptr;
    cell_t* last_ms = nullptr;

    if (context->LocalToPhysAddr(params[1], &hits) != SP_ERROR_NONE
        || context->LocalToPhysAddr(params[2], &misses) != SP_ERROR_NONE
        || context->LocalToPhysAddr(params[3], &dedup) != SP_ERROR_NONE
        || context->LocalToPhysAddr(params[4], &batches) != SP_ERROR_NONE
        || context->LocalToPhysAddr(params[5], &last_ms) != SP_ERROR_NONE) {
        return context->ThrowNativeError("invalid stats reference");
    }

    int h = 0;
    int m = 0;
    int d = 0;
    int b = 0;
    float ms = 0.0f;
    g_ScoreService.stats(h, m, d, b, ms);

    *hits = h;
    *misses = m;
    *dedup = d;
    *batches = b;
    *last_ms = float_to_cell(ms);
    return 0;
}

cell_t Native_GetLastError(IPluginContext* context, const cell_t* params) {
    const int maxlen = params[2];
    if (maxlen <= 0)
        return context->ThrowNativeError("maxlen must be positive");

    const std::string& error = g_ScoreService.last_error();
    context->StringToLocal(params[1], maxlen, error.c_str());
    return static_cast<cell_t>(error.size());
}
}

sp_nativeinfo_t g_SDNNueNatives[] = {
    {"SDNNUE_LoadModel", Native_LoadModel},
    {"SDNNUE_IsReady", Native_IsReady},
    {"SDNNUE_GetInputDim", Native_GetInputDim},
    {"SDNNUE_GetHiddenDim", Native_GetHiddenDim},
    {"SDNNUE_GetMidDim", Native_GetMidDim},
    {"SDNNUE_ConfigureCache", Native_ConfigureCache},
    {"SDNNUE_ClearCache", Native_ClearCache},
    {"SDNNUE_ScoreBatch", Native_ScoreBatch},
    {"SDNNUE_GetStats", Native_GetStats},
    {"SDNNUE_GetLastError", Native_GetLastError},
    {nullptr, nullptr}
};

#include "score_service.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <unordered_map>

ScoreService g_ScoreService;

namespace {
bool ends_with_case_insensitive(const std::string& value, const std::string& suffix) {
    if (value.size() < suffix.size()) return false;
    const std::size_t start = value.size() - suffix.size();
    for (std::size_t i = 0; i < suffix.size(); ++i) {
        const unsigned char lhs = static_cast<unsigned char>(value[start + i]);
        const unsigned char rhs = static_cast<unsigned char>(suffix[i]);
        if (std::tolower(lhs) != std::tolower(rhs)) return false;
    }
    return true;
}
}

bool ScoreService::configure_cache(int mb) {
    if (mb < 1 || mb > 1024) {
        set_error("cache size must be in [1, 1024] MiB");
        return false;
    }
    if (!cache_.resize_mb(static_cast<std::size_t>(mb))) {
        set_error("failed to allocate score cache");
        return false;
    }
    cache_hits_ = 0;
    cache_misses_ = 0;
    batch_dedup_hits_ = 0;
    last_error_.clear();
    return true;
}

void ScoreService::clear_cache() {
    cache_.clear();
    cache_hits_ = 0;
    cache_misses_ = 0;
    batch_dedup_hits_ = 0;
}

bool ScoreService::load_model(const std::string& path) {
    if (!ends_with_case_insensitive(path, ".bin")) {
        set_error("phase-1 backend accepts only .bin/.nnue.bin models");
        return false;
    }

    auto next = std::make_unique<CpuNnueBackend>();
    std::string error;
    if (!next->load(path, error)) {
        set_error(error);
        return false;
    }

    backend_ = std::move(next);
    cache_.clear();
    cache_hits_ = 0;
    cache_misses_ = 0;
    batch_dedup_hits_ = 0;
    inference_batches_ = 0;
    last_inference_ms_ = 0.0f;
    last_error_.clear();
    return true;
}

int ScoreService::score_batch(const std::uint32_t shared[4],
                              const std::uint32_t* candidate_bits,
                              int candidate_count,
                              int words_per_candidate,
                              float* scores,
                              int score_capacity) {
    if (!ready()) {
        set_error("backend is not ready");
        return 0;
    }
    if (!shared || !candidate_bits || !scores
        || candidate_count <= 0 || candidate_count > score_capacity) {
        set_error("invalid candidate/output buffers");
        return 0;
    }
    if (candidate_count > 512) {
        set_error("candidate_count exceeds native maximum of 512");
        return 0;
    }
    if (words_per_candidate != 4) {
        set_error("current schema requires exactly four 32-bit feature words");
        return 0;
    }
    if (input_dim() <= 0 || input_dim() > 128) {
        set_error("unsupported model input dimension");
        return 0;
    }

    miss_bits_.clear();
    miss_scores_.clear();
    miss_keys_.clear();
    row_to_unique_miss_.assign(candidate_count, -1);

    miss_bits_.reserve(static_cast<std::size_t>(candidate_count) * 4);
    miss_keys_.reserve(candidate_count);

    // Candidate position features are intentionally coarse in schema v1, so many physical points
    // map to the same NNUE input. Deduplicate those feature vectors inside the current batch before
    // calling the backend; the persistent clustered cache handles reuse across later decisions.
    std::unordered_map<std::uint64_t, int> pending;
    pending.reserve(static_cast<std::size_t>(candidate_count) * 2);

    for (int row = 0; row < candidate_count; ++row) {
        std::uint32_t full[4];
        for (int word = 0; word < 4; ++word)
            full[word] = shared[word] | candidate_bits[row * words_per_candidate + word];

        const std::uint64_t key = HashFeatureWords(full, 4);
        float cached = 0.0f;
        if (cache_.probe(key, cached)) {
            scores[row] = cached;
            ++cache_hits_;
            continue;
        }

        const auto existing = pending.find(key);
        if (existing != pending.end()) {
            row_to_unique_miss_[row] = existing->second;
            ++batch_dedup_hits_;
            continue;
        }

        const int unique_index = static_cast<int>(miss_keys_.size());
        pending.emplace(key, unique_index);
        row_to_unique_miss_[row] = unique_index;
        miss_keys_.push_back(key);
        for (int word = 0; word < 4; ++word)
            miss_bits_.push_back(full[word]);
        ++cache_misses_;
    }

    const int unique_misses = static_cast<int>(miss_keys_.size());
    if (unique_misses > 0) {
        miss_scores_.resize(unique_misses);
        const auto start = std::chrono::steady_clock::now();

        std::string backend_error;
        if (!backend_->infer_bits(
                miss_bits_.data(), unique_misses, 4, miss_scores_.data(), backend_error)) {
            set_error(backend_error);
            return 0;
        }

        const auto end = std::chrono::steady_clock::now();
        last_inference_ms_ =
            std::chrono::duration<float, std::milli>(end - start).count();
        ++inference_batches_;

        for (int i = 0; i < unique_misses; ++i)
            cache_.store(miss_keys_[i], miss_scores_[i]);

        for (int row = 0; row < candidate_count; ++row) {
            const int source = row_to_unique_miss_[row];
            if (source >= 0)
                scores[row] = miss_scores_[source];
        }
    } else {
        last_inference_ms_ = 0.0f;
    }

    last_error_.clear();
    return candidate_count;
}

void ScoreService::stats(int& cache_hits,
                         int& cache_misses,
                         int& batch_dedup_hits,
                         int& inference_batches,
                         float& last_ms) const {
    cache_hits = cache_hits_;
    cache_misses = cache_misses_;
    batch_dedup_hits = batch_dedup_hits_;
    inference_batches = inference_batches_;
    last_ms = last_inference_ms_;
}

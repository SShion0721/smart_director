#pragma once

#include "cpu_nnue_backend.h"
#include "score_cache.h"

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

class ScoreService {
public:
    bool load_model(const std::string& path);
    bool configure_cache(int mb);
    void clear_cache();

    bool ready() const { return backend_ && backend_->ready(); }
    int input_dim() const { return ready() ? backend_->input_dim() : 0; }
    int hidden_dim() const { return ready() ? backend_->hidden_dim() : 0; }
    int mid_dim() const { return ready() ? backend_->mid_dim() : 0; }

    int score_batch(const std::uint32_t shared[4],
                    const std::uint32_t* candidate_bits,
                    int candidate_count,
                    int words_per_candidate,
                    float* scores,
                    int score_capacity);

    void stats(int& cache_hits,
               int& cache_misses,
               int& batch_dedup_hits,
               int& inference_batches,
               float& last_ms) const;

    const std::string& last_error() const { return last_error_; }

private:
    void set_error(const std::string& error) { last_error_ = error; }

    std::unique_ptr<IInferenceBackend> backend_;
    ScoreCache cache_;
    std::string last_error_;

    int cache_hits_ = 0;
    int cache_misses_ = 0;
    int batch_dedup_hits_ = 0;
    int inference_batches_ = 0;
    float last_inference_ms_ = 0.0f;

    std::vector<std::uint32_t> miss_bits_;
    std::vector<float> miss_scores_;
    std::vector<std::uint64_t> miss_keys_;
    std::vector<int> row_to_unique_miss_;
};

extern ScoreService g_ScoreService;

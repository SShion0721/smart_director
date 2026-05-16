#pragma once

#include "backend.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

class CpuNnueBackend final : public IInferenceBackend {
public:
    bool load(const std::string& path, std::string& error) override;
    bool infer_bits(const std::uint32_t* full_bits,
                    int batch,
                    int words_per_row,
                    float* output,
                    std::string& error) override;

    int input_dim() const override { return input_dim_; }
    int hidden_dim() const override { return hidden_dim_; }
    int mid_dim() const override { return mid_dim_; }
    bool ready() const override { return input_dim_ > 0; }
    const char* name() const override { return "cpu-nnue"; }

private:
    void rebuild_common_accumulator(const std::uint32_t* common, int words_per_row);
    void add_feature_column(float* accumulator, int feature) const;

    int input_dim_ = 0;
    int hidden_dim_ = 0;
    int mid_dim_ = 0;

    std::vector<float> b1_;
    // Transposed once at load time: [input][hidden]. An active sparse feature therefore
    // contributes one contiguous hidden-sized column to the NNUE accumulator.
    std::vector<float> w1_feature_major_;
    std::vector<float> b2_;
    std::vector<float> w2_;
    float b3_ = 0.0f;
    std::vector<float> w3_;

    std::vector<float> base_;
    std::vector<float> hidden_;
    std::vector<float> mid_;
    std::array<std::uint32_t, 4> common_snapshot_{};
    bool common_snapshot_valid_ = false;
};

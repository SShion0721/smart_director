#include "cpu_nnue_backend.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <limits>
#include <vector>

#if defined(_MSC_VER)
#include <intrin.h>
#endif

namespace {
constexpr std::uint32_t kMagic = 0x4E4E5545u; // "NNUE"

template <class T>
bool read_exact(std::ifstream& f, T* ptr, std::size_t count) {
    return static_cast<bool>(f.read(reinterpret_cast<char*>(ptr), sizeof(T) * count));
}

inline int first_set_bit(std::uint32_t x) {
#if defined(_MSC_VER)
    unsigned long index = 0;
    _BitScanForward(&index, x);
    return static_cast<int>(index);
#else
    return __builtin_ctz(x);
#endif
}

bool all_finite(const std::vector<float>& values) {
    for (float value : values) {
        if (!std::isfinite(value)) return false;
    }
    return true;
}
}

bool CpuNnueBackend::load(const std::string& path, std::string& error) {
    input_dim_ = 0;
    hidden_dim_ = 0;
    mid_dim_ = 0;
    b1_.clear();
    w1_feature_major_.clear();
    b2_.clear();
    w2_.clear();
    b3_ = 0.0f;
    w3_.clear();
    base_.clear();
    hidden_.clear();
    mid_.clear();
    common_snapshot_valid_ = false;

    std::ifstream f(path, std::ios::binary);
    if (!f) {
        error = "cannot open NNUE binary: " + path;
        return false;
    }

    std::uint32_t magic = 0;
    std::int32_t input = 0;
    std::int32_t hidden = 0;
    std::int32_t mid = 0;
    if (!read_exact(f, &magic, 1)
        || !read_exact(f, &input, 1)
        || !read_exact(f, &hidden, 1)
        || !read_exact(f, &mid, 1)) {
        error = "truncated NNUE header";
        return false;
    }

    if (magic != kMagic) {
        error = "bad NNUE magic";
        return false;
    }
    if (input <= 0 || input > 128
        || hidden <= 0 || hidden > 4096
        || mid <= 0 || mid > 1024) {
        error = "unsupported NNUE dimensions";
        return false;
    }

    input_dim_ = input;
    hidden_dim_ = hidden;
    mid_dim_ = mid;

    b1_.resize(hidden_dim_);
    std::vector<float> w1_row_major(static_cast<std::size_t>(hidden_dim_) * input_dim_);
    b2_.resize(mid_dim_);
    w2_.resize(static_cast<std::size_t>(mid_dim_) * hidden_dim_);
    w3_.resize(mid_dim_);

    if (!read_exact(f, b1_.data(), b1_.size())
        || !read_exact(f, w1_row_major.data(), w1_row_major.size())
        || !read_exact(f, b2_.data(), b2_.size())
        || !read_exact(f, w2_.data(), w2_.size())
        || !read_exact(f, &b3_, 1)
        || !read_exact(f, w3_.data(), w3_.size())) {
        input_dim_ = 0;
        error = "truncated NNUE weight body";
        return false;
    }

    if (!all_finite(b1_)
        || !all_finite(w1_row_major)
        || !all_finite(b2_)
        || !all_finite(w2_)
        || !std::isfinite(b3_)
        || !all_finite(w3_)) {
        input_dim_ = 0;
        error = "NNUE file contains NaN or infinity";
        return false;
    }

    // PyTorch Linear weights are exported as [out=hidden][in=input]. Incremental NNUE
    // evaluation wants feature columns, so convert once to [input][hidden].
    w1_feature_major_.resize(w1_row_major.size());
    for (int h = 0; h < hidden_dim_; ++h) {
        for (int feature = 0; feature < input_dim_; ++feature) {
            w1_feature_major_[static_cast<std::size_t>(feature) * hidden_dim_ + h] =
                w1_row_major[static_cast<std::size_t>(h) * input_dim_ + feature];
        }
    }

    base_.resize(hidden_dim_);
    hidden_.resize(hidden_dim_);
    mid_.resize(mid_dim_);
    error.clear();
    return true;
}

void CpuNnueBackend::add_feature_column(float* accumulator, int feature) const {
    const float* column = &w1_feature_major_[static_cast<std::size_t>(feature) * hidden_dim_];
    for (int h = 0; h < hidden_dim_; ++h)
        accumulator[h] += column[h];
}

void CpuNnueBackend::rebuild_common_accumulator(const std::uint32_t* common,
                                                 int words_per_row) {
    bool same = common_snapshot_valid_;
    if (same) {
        for (int w = 0; w < words_per_row; ++w) {
            if (common_snapshot_[w] != common[w]) {
                same = false;
                break;
            }
        }
    }
    if (same) return;

    std::copy(b1_.begin(), b1_.end(), base_.begin());

    for (int word = 0; word < words_per_row; ++word) {
        std::uint32_t bits = common[word];
        while (bits) {
            const int bit = first_set_bit(bits);
            const int feature = word * 32 + bit;
            if (feature < input_dim_)
                add_feature_column(base_.data(), feature);
            bits &= bits - 1;
        }
    }

    for (int w = 0; w < 4; ++w)
        common_snapshot_[w] = (w < words_per_row) ? common[w] : 0;
    common_snapshot_valid_ = true;
}

bool CpuNnueBackend::infer_bits(const std::uint32_t* full_bits,
                                int batch,
                                int words_per_row,
                                float* output,
                                std::string& error) {
    if (!ready()) {
        error = "CPU NNUE backend is not ready";
        return false;
    }
    if (!full_bits || !output || batch <= 0 || words_per_row <= 0 || words_per_row > 4) {
        error = "invalid input buffer";
        return false;
    }
    if (words_per_row * 32 < input_dim_) {
        error = "feature bitset is smaller than model input dimension";
        return false;
    }

    // All rows in one Director decision share the same game state and SI action. Their exact
    // bitwise intersection is therefore a reusable NNUE base accumulator.
    std::uint32_t common[4] = {0xffffffffu, 0xffffffffu, 0xffffffffu, 0xffffffffu};
    for (int row = 0; row < batch; ++row) {
        for (int word = 0; word < words_per_row; ++word)
            common[word] &= full_bits[row * words_per_row + word];
    }
    rebuild_common_accumulator(common, words_per_row);

    for (int row_index = 0; row_index < batch; ++row_index) {
        std::copy(base_.begin(), base_.end(), hidden_.begin());
        const std::uint32_t* row = full_bits + row_index * words_per_row;

        // Add only row-specific sparse columns. Complexity is O(active_delta * hidden), not
        // O(input * hidden), which is the main reason to keep the first deployment as NNUE.
        for (int word = 0; word < words_per_row; ++word) {
            std::uint32_t bits = row[word] & ~common[word];
            while (bits) {
                const int bit = first_set_bit(bits);
                const int feature = word * 32 + bit;
                if (feature < input_dim_)
                    add_feature_column(hidden_.data(), feature);
                bits &= bits - 1;
            }
        }

        for (float& value : hidden_)
            value = std::min(127.0f, std::max(0.0f, value));

        for (int m = 0; m < mid_dim_; ++m) {
            float value = b2_[m];
            const float* weights = &w2_[static_cast<std::size_t>(m) * hidden_dim_];
            for (int h = 0; h < hidden_dim_; ++h)
                value += hidden_[h] * weights[h];
            mid_[m] = std::min(127.0f, std::max(0.0f, value));
        }

        float score = b3_;
        for (int m = 0; m < mid_dim_; ++m)
            score += mid_[m] * w3_[m];

        if (!std::isfinite(score)) {
            error = "NNUE produced a non-finite score";
            return false;
        }
        output[row_index] = score;
    }

    error.clear();
    return true;
}

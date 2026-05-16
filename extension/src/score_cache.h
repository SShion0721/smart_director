#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

class ScoreCache {
public:
    struct alignas(16) Entry {
        std::uint64_t key = 0;
        float value = 0.0f;
        std::uint32_t stamp = 0;
    };

    struct alignas(64) Cluster {
        Entry entries[4];
    };

    static_assert(sizeof(Entry) == 16, "score-cache entry must stay compact");
    static_assert(sizeof(Cluster) == 64, "one score-cache cluster should occupy one cache line");

    bool resize_mb(std::size_t mb);
    void clear();
    bool probe(std::uint64_t key, float& value);
    void store(std::uint64_t key, float value);
    std::size_t bytes() const { return clusters_.size() * sizeof(Cluster); }

private:
    std::vector<Cluster> clusters_;
    std::uint32_t clock_ = 1;
};

std::uint64_t HashFeatureWords(const std::uint32_t* words, std::size_t count);

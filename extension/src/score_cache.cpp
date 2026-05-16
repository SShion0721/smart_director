#include "score_cache.h"

#include <algorithm>
#include <cstdint>

namespace {
std::uint64_t mix64(std::uint64_t value) {
    value ^= value >> 30;
    value *= 0xbf58476d1ce4e5b9ULL;
    value ^= value >> 27;
    value *= 0x94d049bb133111ebULL;
    value ^= value >> 31;
    return value;
}
}

std::uint64_t HashFeatureWords(const std::uint32_t* words, std::size_t count) {
    std::uint64_t hash = 0x9e3779b97f4a7c15ULL;
    for (std::size_t i = 0; i < count; ++i) {
        hash = mix64(hash ^ (std::uint64_t(words[i])
            + 0x9e3779b97f4a7c15ULL * (i + 1)));
    }
    return hash ? hash : 1ULL;
}

bool ScoreCache::resize_mb(std::size_t mb) {
    if (mb == 0) mb = 1;

    const std::size_t target_clusters = (mb * 1024ULL * 1024ULL) / sizeof(Cluster);
    std::size_t power_of_two = 1;
    while ((power_of_two << 1) <= target_clusters)
        power_of_two <<= 1;

    try {
        clusters_.assign(std::max<std::size_t>(1, power_of_two), Cluster{});
    } catch (...) {
        return false;
    }

    clock_ = 1;
    return true;
}

void ScoreCache::clear() {
    std::fill(clusters_.begin(), clusters_.end(), Cluster{});
    clock_ = 1;
}

bool ScoreCache::probe(std::uint64_t key, float& value) {
    if (clusters_.empty()) return false;

    Cluster& cluster = clusters_[key & (clusters_.size() - 1)];
    for (Entry& entry : cluster.entries) {
        if (entry.key != key) continue;
        value = entry.value;
        entry.stamp = ++clock_;
        return true;
    }
    return false;
}

void ScoreCache::store(std::uint64_t key, float value) {
    if (clusters_.empty()) return;

    Cluster& cluster = clusters_[key & (clusters_.size() - 1)];
    Entry* replacement = &cluster.entries[0];

    for (Entry& entry : cluster.entries) {
        if (entry.key == key || entry.key == 0) {
            replacement = &entry;
            break;
        }
        if (entry.stamp < replacement->stamp)
            replacement = &entry;
    }

    replacement->key = key;
    replacement->value = value;
    replacement->stamp = ++clock_;
}

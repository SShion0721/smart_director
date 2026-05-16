#pragma once

#include <cstdint>
#include <string>

class IInferenceBackend {
public:
    virtual ~IInferenceBackend() = default;
    virtual bool load(const std::string& path, std::string& error) = 0;
    virtual bool infer_bits(const std::uint32_t* full_bits,
                            int batch,
                            int words_per_row,
                            float* output,
                            std::string& error) = 0;
    virtual int input_dim() const = 0;
    virtual int hidden_dim() const = 0;
    virtual int mid_dim() const = 0;
    virtual bool ready() const = 0;
    virtual const char* name() const = 0;
};

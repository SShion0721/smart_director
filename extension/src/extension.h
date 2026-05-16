#pragma once

#include "smsdk_ext.h"

class SDNNUEExtension final : public SDKExtension {
public:
    bool SDK_OnLoad(char* error, size_t maxlength, bool late) override;
    void SDK_OnUnload() override;
};

extern SDNNUEExtension g_SDNNUEExtension;
extern sp_nativeinfo_t g_SDNNueNatives[];

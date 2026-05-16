#include "extension.h"
#include "score_service.h"

#include <cstdio>

SDNNUEExtension g_SDNNUEExtension;
SMEXT_LINK(&g_SDNNUEExtension);

bool SDNNUEExtension::SDK_OnLoad(char* error, size_t maxlength, bool late) {
    (void)late;
    sharesys->AddNatives(myself, g_SDNNueNatives);
    sharesys->RegisterLibrary(myself, "sd_nnue");

    if (!g_ScoreService.configure_cache(16)) {
        std::snprintf(error, maxlength, "failed to allocate default NNUE score cache");
        return false;
    }
    return true;
}

void SDNNUEExtension::SDK_OnUnload() {
    g_ScoreService.clear_cache();
}

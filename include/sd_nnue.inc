#if defined _sd_nnue_included
    #endinput
#endif
#define _sd_nnue_included

#define SDNNUE_FEATURE_WORDS 4
#define SDNNUE_MAX_FEATURES  128

/** Load a native NNUE .bin model. The path must be absolute. */
native bool SDNNUE_LoadModel(const char[] path);
/** True when a model is loaded and the backend can execute inference. */
native bool SDNNUE_IsReady();
/** Model dimensions. */
native int SDNNUE_GetInputDim();
native int SDNNUE_GetHiddenDim();
native int SDNNUE_GetMidDim();
/** Configure the 4-way clustered score cache. */
native bool SDNNUE_ConfigureCache(int megabytes);
/** Clear all cached scores. */
native void SDNNUE_ClearCache();
/**
 * Score candidate feature bitsets in one native call.
 * sharedBits are OR'ed with each candidate row inside the extension.
 * candidateBits is a flat array: candidateCount * wordsPerCandidate cells.
 */
native int SDNNUE_ScoreBatch(const int[] sharedBits,
                             const int[] candidateBits,
                             int candidateCount,
                             int wordsPerCandidate,
                             float[] scores,
                             int scoreCapacity);
/** Runtime statistics for the score cache and real NNUE inference work. */
native void SDNNUE_GetStats(int &cacheHits,
                            int &cacheMisses,
                            int &batchDedupHits,
                            int &inferenceBatches,
                            float &lastInferenceMs);
/** Copy the latest backend error message into buffer. */
native int SDNNUE_GetLastError(char[] buffer, int maxlen);

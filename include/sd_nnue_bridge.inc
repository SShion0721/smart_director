#if defined _sd_nnue_bridge_included
    #endinput
#endif
#define _sd_nnue_bridge_included

#include "sd_nnue.inc"

#define SDNNUE_SCHEMA_INPUTS          106
#define SDNNUE_MAX_CANDIDATES         256

// Feature indices stay compatible with the existing nnue_director 106-input schema.
#define SDNNUE_FEAT_TEAM_ALL_GREEN       0
#define SDNNUE_FEAT_TEAM_ANY_INCAP       1
#define SDNNUE_FEAT_TEAM_MULTIPLE_INCAP  2
#define SDNNUE_FEAT_TEAM_ANY_DEAD        3
#define SDNNUE_FEAT_TEAM_ANY_BILED       8
#define SDNNUE_FEAT_TEAM_GROUP_TIGHT     9
#define SDNNUE_FEAT_TEAM_SEPARATED      10
#define SDNNUE_FEAT_SI_HUNTER_READY     17
#define SDNNUE_FEAT_SI_SMOKER_READY     18
#define SDNNUE_FEAT_SI_BOOMER_READY     19
#define SDNNUE_FEAT_SI_CHARGER_READY    20
#define SDNNUE_FEAT_SI_SPITTER_READY    21
#define SDNNUE_FEAT_SI_JOCKEY_READY     22
#define SDNNUE_FEAT_SI_HUNTER_PINNING   23
#define SDNNUE_FEAT_SI_SMOKER_CHOKING   24
#define SDNNUE_FEAT_SI_CHARGER_PINNING  25
#define SDNNUE_FEAT_SI_JOCKEY_RIDING    26
#define SDNNUE_FEAT_ENV_HORDE_ACTIVE    28
#define SDNNUE_FEAT_ENV_TANK_ALIVE      29
#define SDNNUE_FEAT_FLOW_PAST_HALF      31
#define SDNNUE_FEAT_FLOW_PAST_80        32
#define SDNNUE_FEAT_SURV_HP_LOW_40      35
#define SDNNUE_FEAT_SURV_HP_LOW_20      36
#define SDNNUE_FEAT_TEAM_AVG_HP_LOW     38
#define SDNNUE_FEAT_SI_HUNTER_MULTI     43
#define SDNNUE_FEAT_SI_SMOKER_MULTI     44
#define SDNNUE_FEAT_SI_FORCE_HEAVY      45
#define SDNNUE_FEAT_MAP_IS_FINALE       56
#define SDNNUE_FEAT_FLOW_0_20           74
#define SDNNUE_FEAT_FLOW_20_40          75
#define SDNNUE_FEAT_FLOW_40_60          76
#define SDNNUE_FEAT_FLOW_60_80          77
#define SDNNUE_FEAT_FLOW_80_100         78
#define SDNNUE_FEAT_TEAM_HP_0_25        79
#define SDNNUE_FEAT_TEAM_HP_25_50       80
#define SDNNUE_FEAT_TEAM_HP_50_75       81
#define SDNNUE_FEAT_TEAM_HP_75_100      82
#define SDNNUE_FEAT_POS_DIST_CLOSE      87
#define SDNNUE_FEAT_POS_DIST_OPTIMAL    88
#define SDNNUE_FEAT_POS_DIST_FAR        89
#define SDNNUE_FEAT_POS_HEIGHT_ABOVE    90
#define SDNNUE_FEAT_POS_HEIGHT_BELOW    91
#define SDNNUE_FEAT_POS_FLOW_AHEAD      92
#define SDNNUE_FEAT_POS_FLOW_BEHIND     93
#define SDNNUE_FEAT_POS_HIDDEN          94
#define SDNNUE_FEAT_POS_EXPOSED         95
#define SDNNUE_ACTION_BASE             100

ConVar g_cvNNUE_ModelPath;
ConVar g_cvNNUE_MaxCandidates;
ConVar g_cvNNUE_SamplesPerBucket;
ConVar g_cvNNUE_MaxPathChecks;
ConVar g_cvNNUE_CacheMB;
ConVar g_cvNNUE_Debug;

bool  g_bNNUEExtensionPresent = false;
bool  g_bNNUEBackendReady     = false;
int   g_iNNUECandidateCount    = 0;
int   g_iNNUESharedBits[SDNNUE_FEATURE_WORDS];
int   g_iNNUECandidateBits[SDNNUE_MAX_CANDIDATES * SDNNUE_FEATURE_WORDS];
float g_fNNUECandidatePos[SDNNUE_MAX_CANDIDATES][3];
float g_fNNUEScores[SDNNUE_MAX_CANDIDATES];

stock void SDNNUE_MarkNativesOptional()
{
    MarkNativeAsOptional("SDNNUE_LoadModel");
    MarkNativeAsOptional("SDNNUE_IsReady");
    MarkNativeAsOptional("SDNNUE_GetInputDim");
    MarkNativeAsOptional("SDNNUE_GetHiddenDim");
    MarkNativeAsOptional("SDNNUE_GetMidDim");
    MarkNativeAsOptional("SDNNUE_ConfigureCache");
    MarkNativeAsOptional("SDNNUE_ClearCache");
    MarkNativeAsOptional("SDNNUE_ScoreBatch");
    MarkNativeAsOptional("SDNNUE_GetStats");
    MarkNativeAsOptional("SDNNUE_GetLastError");
}

stock void SDNNUE_CreateConVars()
{
    g_cvNNUE_ModelPath = CreateConVar(
        "sd_nnue_model",
        "data/smart_director/nnue_weights.bin",
        "NNUE model path relative to addons/sourcemod");
    g_cvNNUE_MaxCandidates = CreateConVar(
        "sd_nnue_max_candidates",
        "192",
        "Maximum cheap-legal candidates sent to one NNUE batch",
        _, true, 1.0, true, float(SDNNUE_MAX_CANDIDATES));
    g_cvNNUE_SamplesPerBucket = CreateConVar(
        "sd_nnue_samples_per_bucket",
        "8",
        "Maximum NavArea samples taken from each Flow bucket",
        _, true, 1.0, true, 32.0);
    g_cvNNUE_MaxPathChecks = CreateConVar(
        "sd_nnue_max_path_checks",
        "16",
        "Maximum ranked candidates receiving the expensive Nav path validation",
        _, true, 1.0, true, 64.0);
    g_cvNNUE_CacheMB = CreateConVar(
        "sd_nnue_cache_mb",
        "16",
        "Native clustered NNUE score-cache size in MiB",
        _, true, 1.0, true, 256.0);
    g_cvNNUE_Debug = CreateConVar(
        "sd_nnue_debug",
        "0",
        "Print NNUE candidate-ranking diagnostics",
        _, true, 0.0, true, 1.0);

    g_cvNNUE_ModelPath.AddChangeHook(SDNNUE_OnRuntimeConfigChanged);
    g_cvNNUE_CacheMB.AddChangeHook(SDNNUE_OnRuntimeConfigChanged);

    RegAdminCmd("sm_sd_nnue_status", Cmd_SDNNUE_Status, ADMFLAG_ROOT,
        "Show Smart Director NNUE backend status");
    RegAdminCmd("sm_sd_nnue_reload", Cmd_SDNNUE_Reload, ADMFLAG_ROOT,
        "Reload Smart Director NNUE weights and clear score cache");
}

public void SDNNUE_OnRuntimeConfigChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    SDNNUE_RefreshRuntime();
}

stock void SDNNUE_GetBackendError(char[] buffer, int maxlen)
{
    if (!g_bNNUEExtensionPresent)
    {
        strcopy(buffer, maxlen, "sd_nnue extension is not loaded");
        return;
    }

    if (SDNNUE_GetLastError(buffer, maxlen) <= 0)
        strcopy(buffer, maxlen, "unknown backend error");
}

stock void SDNNUE_RefreshRuntime()
{
    if (g_cvNNUE_ModelPath == null) return;

    g_bNNUEExtensionPresent = LibraryExists("sd_nnue");
    g_bNNUEBackendReady = false;
    if (!g_bNNUEExtensionPresent)
    {
        LogMessage("[SD-NNUE] native extension is not loaded; normal SI will use engine fallback until it is available");
        return;
    }

    int cacheMB = g_cvNNUE_CacheMB.IntValue;
    if (!SDNNUE_ConfigureCache(cacheMB))
    {
        char cacheError[256];
        SDNNUE_GetBackendError(cacheError, sizeof(cacheError));
        LogError("[SD-NNUE] cache configuration failed: %s", cacheError);
        return;
    }

    char relativePath[PLATFORM_MAX_PATH];
    char absolutePath[PLATFORM_MAX_PATH];
    g_cvNNUE_ModelPath.GetString(relativePath, sizeof(relativePath));
    BuildPath(Path_SM, absolutePath, sizeof(absolutePath), "%s", relativePath);

    if (!SDNNUE_LoadModel(absolutePath))
    {
        char loadError[256];
        SDNNUE_GetBackendError(loadError, sizeof(loadError));
        LogError("[SD-NNUE] model load failed (%s): %s", absolutePath, loadError);
        return;
    }

    int inputDim = SDNNUE_GetInputDim();
    if (inputDim != SDNNUE_SCHEMA_INPUTS)
    {
        LogError("[SD-NNUE] model input dimension is %d; current feature schema requires %d",
            inputDim, SDNNUE_SCHEMA_INPUTS);
        return;
    }

    g_bNNUEBackendReady = SDNNUE_IsReady();
    if (g_bNNUEBackendReady)
    {
        LogMessage("[SD-NNUE] CPU backend ready: %d -> %d -> %d -> 1, cache=%d MiB, model=%s",
            inputDim, SDNNUE_GetHiddenDim(), SDNNUE_GetMidDim(), cacheMB, absolutePath);
    }
}

stock bool SDNNUE_IsOperationalForClass(int zClass)
{
    return g_bNNUEExtensionPresent
        && g_bNNUEBackendReady
        && zClass >= ZC_SMOKER
        && zClass <= ZC_CHARGER;
}

stock void SDNNUE_ClearWords(int bits[SDNNUE_FEATURE_WORDS])
{
    for (int i = 0; i < SDNNUE_FEATURE_WORDS; i++) bits[i] = 0;
}

stock void SDNNUE_SetSharedBit(int feature)
{
    if (feature < 0 || feature >= SDNNUE_MAX_FEATURES) return;
    g_iNNUESharedBits[feature >> 5] |= (1 << (feature & 31));
}

stock void SDNNUE_SetCandidateBit(int row, int feature)
{
    if (row < 0 || row >= SDNNUE_MAX_CANDIDATES) return;
    if (feature < 0 || feature >= SDNNUE_MAX_FEATURES) return;

    int idx = row * SDNNUE_FEATURE_WORDS + (feature >> 5);
    g_iNNUECandidateBits[idx] |= (1 << (feature & 31));
}

stock void SDNNUE_BuildSharedFeatures()
{
    SDNNUE_ClearWords(g_iNNUESharedBits);

    int alive = 0;
    int incap = 0;
    int connectedSurvivors = 0;
    int dead = 0;
    int hpSum = 0;
    bool allGreen = true;
    bool anyBiled = false;
    float positions[MAXPLAYERS + 1][3];
    int posCount = 0;
    int flowSumPct = 0;
    int flowCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_bCachedInGame[i] || g_iCachedTeam[i] != TEAM_SURVIVOR)
            continue;

        connectedSurvivors++;
        if (!g_bCachedAlive[i])
        {
            dead++;
            continue;
        }

        alive++;
        int hp = GetClientHealth(i);
        hpSum += hp;
        if (hp < 80 || g_bIsIncap[i]) allGreen = false;
        if (g_bIsIncap[i]) incap++;
        if (g_bIsBiled[i]) anyBiled = true;
        if (hp < 40) SDNNUE_SetSharedBit(SDNNUE_FEAT_SURV_HP_LOW_40);
        if (hp < 20) SDNNUE_SetSharedBit(SDNNUE_FEAT_SURV_HP_LOW_20);

        GetClientAbsOrigin(i, positions[posCount]);
        posCount++;

        int pct;
        if (TryGetClientFlowPercentSafe(i, pct))
        {
            flowSumPct += pct;
            flowCount++;
        }
    }

    if (alive > 0 && allGreen) SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_ALL_GREEN);
    if (incap > 0) SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_ANY_INCAP);
    if (incap >= 2) SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_MULTIPLE_INCAP);
    if (dead > 0 || (connectedSurvivors > 0 && alive < connectedSurvivors))
        SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_ANY_DEAD);
    if (anyBiled) SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_ANY_BILED);

    if (alive > 0)
    {
        float avgHp = float(hpSum) / float(alive);
        if (avgHp < 50.0) SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_AVG_HP_LOW);

        if (avgHp < 25.0) SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_HP_0_25);
        else if (avgHp < 50.0) SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_HP_25_50);
        else if (avgHp < 75.0) SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_HP_50_75);
        else SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_HP_75_100);
    }

    if (posCount >= 2)
    {
        float maxDistSq = 0.0;
        for (int a = 0; a < posCount; a++)
        {
            for (int b = a + 1; b < posCount; b++)
            {
                float dx = positions[a][0] - positions[b][0];
                float dy = positions[a][1] - positions[b][1];
                float dz = positions[a][2] - positions[b][2];
                float d2 = dx * dx + dy * dy + dz * dz;
                if (d2 > maxDistSq) maxDistSq = d2;
            }
        }

        if (maxDistSq < 400.0 * 400.0)
            SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_GROUP_TIGHT);
        if (maxDistSq > 1200.0 * 1200.0)
            SDNNUE_SetSharedBit(SDNNUE_FEAT_TEAM_SEPARATED);
    }

    int hunter = 0;
    int smoker = 0;
    int boomer = 0;
    int charger = 0;
    int spitter = 0;
    int jockey = 0;
    int siTotal = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!(g_iInfectedMask & (1 << i))) continue;

        int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
        siTotal++;

        if (zc == ZC_HUNTER)
        {
            hunter++;
            if (GetEntPropEnt(i, Prop_Send, "m_pounceVictim") > 0)
                SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_HUNTER_PINNING);
        }
        else if (zc == ZC_SMOKER)
        {
            smoker++;
            if (GetEntPropEnt(i, Prop_Send, "m_tongueVictim") > 0)
                SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_SMOKER_CHOKING);
        }
        else if (zc == ZC_BOOMER)
        {
            boomer++;
        }
        else if (zc == ZC_CHARGER)
        {
            charger++;
            if (GetEntPropEnt(i, Prop_Send, "m_pummelVictim") > 0
                || GetEntPropEnt(i, Prop_Send, "m_carryVictim") > 0)
                SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_CHARGER_PINNING);
        }
        else if (zc == ZC_SPITTER)
        {
            spitter++;
        }
        else if (zc == ZC_JOCKEY)
        {
            jockey++;
            if (GetEntPropEnt(i, Prop_Send, "m_jockeyVictim") > 0)
                SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_JOCKEY_RIDING);
        }
    }

    if (hunter > 0) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_HUNTER_READY);
    if (smoker > 0) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_SMOKER_READY);
    if (boomer > 0) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_BOOMER_READY);
    if (charger > 0) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_CHARGER_READY);
    if (spitter > 0) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_SPITTER_READY);
    if (jockey > 0) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_JOCKEY_READY);
    if (hunter >= 2) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_HUNTER_MULTI);
    if (smoker >= 2) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_SMOKER_MULTI);
    if (siTotal + g_iTotalPending >= 6) SDNNUE_SetSharedBit(SDNNUE_FEAT_SI_FORCE_HEAVY);

    if (g_bPanicMode) SDNNUE_SetSharedBit(SDNNUE_FEAT_ENV_HORDE_ACTIVE);
    if (SD_IsTankAlive()) SDNNUE_SetSharedBit(SDNNUE_FEAT_ENV_TANK_ALIVE);
    if (L4D_IsMissionFinalMap()) SDNNUE_SetSharedBit(SDNNUE_FEAT_MAP_IS_FINALE);

    if (flowCount > 0)
    {
        int avgFlow = flowSumPct / flowCount;
        if (avgFlow > 50) SDNNUE_SetSharedBit(SDNNUE_FEAT_FLOW_PAST_HALF);
        if (avgFlow > 80) SDNNUE_SetSharedBit(SDNNUE_FEAT_FLOW_PAST_80);

        if (avgFlow < 20) SDNNUE_SetSharedBit(SDNNUE_FEAT_FLOW_0_20);
        else if (avgFlow < 40) SDNNUE_SetSharedBit(SDNNUE_FEAT_FLOW_20_40);
        else if (avgFlow < 60) SDNNUE_SetSharedBit(SDNNUE_FEAT_FLOW_40_60);
        else if (avgFlow < 80) SDNNUE_SetSharedBit(SDNNUE_FEAT_FLOW_60_80);
        else SDNNUE_SetSharedBit(SDNNUE_FEAT_FLOW_80_100);
    }
}

stock void SDNNUE_ResetCandidates()
{
    g_iNNUECandidateCount = 0;
    for (int i = 0; i < SDNNUE_MAX_CANDIDATES * SDNNUE_FEATURE_WORDS; i++)
        g_iNNUECandidateBits[i] = 0;
}

stock int SDNNUE_AddCandidate(const float pos[3],
                              int zClass,
                              float dist,
                              float heightDiff,
                              int candidateBucket,
                              int leaderPercent,
                              int visibilityState)
{
    if (g_iNNUECandidateCount >= SDNNUE_MAX_CANDIDATES) return -1;

    int row = g_iNNUECandidateCount++;
    g_fNNUECandidatePos[row][0] = pos[0];
    g_fNNUECandidatePos[row][1] = pos[1];
    g_fNNUECandidatePos[row][2] = pos[2];

    if (dist < 300.0) SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_DIST_CLOSE);
    else if (dist < 600.0) SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_DIST_OPTIMAL);
    else if (dist > 800.0) SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_DIST_FAR);

    if (heightDiff > 100.0) SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_HEIGHT_ABOVE);
    else if (heightDiff < -50.0) SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_HEIGHT_BELOW);

    if (candidateBucket > leaderPercent)
        SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_FLOW_AHEAD);
    else
        SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_FLOW_BEHIND);

    if (visibilityState > 0)
        SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_HIDDEN);
    else if (visibilityState == 0)
        SDNNUE_SetCandidateBit(row, SDNNUE_FEAT_POS_EXPOSED);

    if (zClass >= ZC_SMOKER && zClass <= ZC_CHARGER)
        SDNNUE_SetCandidateBit(row, SDNNUE_ACTION_BASE + zClass - 1);

    return row;
}

stock int SDNNUE_GetLeaderPercent()
{
    int leader = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvFast(i) || g_bIsIncap[i]) continue;

        int pct;
        if (TryGetClientFlowPercentSafe(i, pct) && pct > leader)
            leader = pct;
    }
    return leader;
}

stock int SDNNUE_ScoreCandidates()
{
    if (g_iNNUECandidateCount <= 0 || !g_bNNUEBackendReady)
        return 0;

    int written = SDNNUE_ScoreBatch(
        g_iNNUESharedBits,
        g_iNNUECandidateBits,
        g_iNNUECandidateCount,
        SDNNUE_FEATURE_WORDS,
        g_fNNUEScores,
        SDNNUE_MAX_CANDIDATES);

    if (written != g_iNNUECandidateCount)
    {
        if (g_cvNNUE_Debug.BoolValue)
        {
            char backendError[256];
            SDNNUE_GetBackendError(backendError, sizeof(backendError));
            PrintToServer("[SD-NNUE] score batch failed: expected=%d got=%d error=%s",
                g_iNNUECandidateCount, written, backendError);
        }
        return 0;
    }

    return written;
}

stock int SDNNUE_ArgMaxUntried(const bool tried[SDNNUE_MAX_CANDIDATES], int count)
{
    int best = -1;
    float bestScore = -1000000000.0;

    for (int i = 0; i < count; i++)
    {
        if (tried[i]) continue;
        if (best < 0 || g_fNNUEScores[i] > bestScore)
        {
            best = i;
            bestScore = g_fNNUEScores[i];
        }
    }
    return best;
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "sd_nnue"))
        SDNNUE_RefreshRuntime();
}

public void OnLibraryRemoved(const char[] name)
{
    if (!StrEqual(name, "sd_nnue")) return;

    g_bNNUEExtensionPresent = false;
    g_bNNUEBackendReady = false;
}

public Action Cmd_SDNNUE_Status(int client, int args)
{
    int cacheHits = 0;
    int cacheMisses = 0;
    int dedupHits = 0;
    int batches = 0;
    float lastMs = 0.0;

    if (g_bNNUEExtensionPresent)
        SDNNUE_GetStats(cacheHits, cacheMisses, dedupHits, batches, lastMs);

    char backendError[256];
    SDNNUE_GetBackendError(backendError, sizeof(backendError));

    ReplyToCommand(client,
        "[SD-NNUE] extension=%d ready=%d model=%d->%d->%d->1 cache(h/m/dedup)=%d/%d/%d batches=%d last=%.4fms error=%s",
        g_bNNUEExtensionPresent ? 1 : 0,
        g_bNNUEBackendReady ? 1 : 0,
        g_bNNUEBackendReady ? SDNNUE_GetInputDim() : 0,
        g_bNNUEBackendReady ? SDNNUE_GetHiddenDim() : 0,
        g_bNNUEBackendReady ? SDNNUE_GetMidDim() : 0,
        cacheHits, cacheMisses, dedupHits, batches, lastMs, backendError);

    return Plugin_Handled;
}

public Action Cmd_SDNNUE_Reload(int client, int args)
{
    SDNNUE_RefreshRuntime();
    ReplyToCommand(client, "[SD-NNUE] reload requested; use sm_sd_nnue_status to inspect the backend");
    return Plugin_Handled;
}

/**
 * Smart Director 纯规则版
 * 根据队伍状态、Nav Flow 和难度配置管理特感队列与生成位置。
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <sourcescramble>
#pragma semicolon 1
#pragma newdecls required

#define SUPER_ADMIN_STEAMID "STEAM_0:0:814326156"

#define TEAM_SURVIVOR         2
#define TEAM_INFECTED         3

#define ZC_SMOKER             1
#define ZC_BOOMER             2
#define ZC_HUNTER             3
#define ZC_SPITTER            4
#define ZC_JOCKEY             5
#define ZC_CHARGER            6
#define ZC_TANK               8

#define PATH_NO_BUILD_PENALTY 1999.0

ArrayList g_hGriefTargets;
char      g_sGriefFilePath[PLATFORM_MAX_PATH];

int       g_iPendingSI[MAXPLAYERS + 1];
int       g_iTotalPending = 0;

#define IsValidClient(%1)   (%1 > 0 && %1 <= MaxClients && IsClientInGame(%1))
#define IsSurvivor(%1)      (IsValidClient(%1) && GetClientTeam(%1) == TEAM_SURVIVOR)
#define IsInfected(%1)      (IsValidClient(%1) && GetClientTeam(%1) == TEAM_INFECTED)
#define IsAlive(%1)         (IsPlayerAlive(%1))

// 快速判断读取事件维护的客户端 mask。
#define IsValidSurvFast(%1) (g_iSurvivorMask & (1 << %1))
#define IsValidInfFast(%1)  (g_iInfectedMask & (1 << %1))

static int  g_ProbFullControl[101];
static int  g_ProbMobFront[101];
static char g_sLogicCachePath[PLATFORM_MAX_PATH] = "";
static bool g_bLogicReady                        = false;

#define LOGIC_CURVE_EXP   2.5
#define LOGIC_BASE_CHANCE 5.0
#define LOGIC_MAX_CHANCE  90.0

char      g_sClassNames[][] = { "Unknown", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger", "Witch", "Tank" };

int       g_iSurvivorMask   = 0;
int       g_iInfectedMask   = 0;
// 生成成功后保留半秒计数缓冲。
int       g_iSpawnGhosts[10];
int       g_iCachedBestTarget  = -1;

bool      g_bTerminalIntercept = false;

float     g_fLastMobTime       = 0.0;

bool      g_bIsPluginSpawning  = false;

ConVar    g_cvPhantomMaxSounds;

ConVar    g_cvMaxSI;
ConVar    g_cvSpawnDistMin;
ConVar    g_cvSpawnDistMax;
ConVar    g_cvEnableTankControl;
ConVar    g_cvCullDistance;
ConVar    g_cvDebugMode;
ConVar    g_cvHungerCooldown;
ConVar    g_cvLimitBatchHalf;
ConVar    g_cvCheckVis;
ConVar    g_cvmobcooldown;
ConVar    g_cvTankChance;

ConVar    g_cvSilentSI;

int       g_iCapSmoker  = 6;
int       g_iCapBoomer  = 1;
int       g_iCapHunter  = 6;
int       g_iCapSpitter = 2;
int       g_iCapJockey  = 6;
int       g_iCapCharger = 8;

ConVar    g_cvDifficultyTier;
float     g_fLastTankMobTime = 0.0;
ConVar    g_cvPhantomChance;

Handle    g_hSpawnTimer       = null;
Handle    g_hCacheTimer       = null;
Handle    g_hQueueTimer       = null;
ArrayList g_hSpawnQueue       = null;
bool      g_bTankSpawnedRound = false;

bool      g_bSuperMode        = false;

bool      g_bPanicMode        = false;
float     g_fOriginalMinDist;
float     g_fOriginalMaxDist;
Handle    g_hPanicEndTimer  = null;

float     g_fNextTankTime   = 0.0;
float     g_fLastSupplyTime = 0.0;
bool      g_bLateLoad       = false;
bool      g_bLeftSafeArea   = false;
float     fPathCacheQuantize;

float     g_fFlowCache[MAXPLAYERS + 1];
float     g_fLastMaxFlow = 0.0;
float     g_vLastFlowPos[MAXPLAYERS + 1][3];
bool      g_bIsPinned[MAXPLAYERS + 1];
bool      g_bIsIncap[MAXPLAYERS + 1];
bool      g_bIsBiled[MAXPLAYERS + 1];
// 生成时间用于新特感的清理保护期。
float     g_fSpawnTime[MAXPLAYERS + 1];

bool      g_bForceMobFront = false;

int       g_iCachedTeam[MAXPLAYERS + 1];
bool      g_bCachedAlive[MAXPLAYERS + 1];
bool      g_bCachedInGame[MAXPLAYERS + 1];

ConVar    g_cvPhantomIntervalMin;
ConVar    g_cvPhantomIntervalMax;
Handle    g_hPhantomTimer = null;

enum struct SurPosData
{
    float fFlow;
    float fPos[3];
}

#define FLOW_BUCKETS     101
#define BUCKET_CACHE_VER "2026.2.10"

StringMap        g_NavCooldown;

static ArrayList g_AllNavAreasCache   = null;
static int       g_NavAreasCacheCount = 0;

static ArrayList g_AreaZCore          = null;
static ArrayList g_AreaZMin           = null;
static ArrayList g_AreaZMax           = null;
static float     g_BucketMinZ[FLOW_BUCKETS];
static float     g_BucketMaxZ[FLOW_BUCKETS];

static StringMap g_NavIdToIndex                        = null;
static char      g_sBucketCachePath[PLATFORM_MAX_PATH] = "";

static int       g_LastGoodSurPct                      = -1;
static float     g_LastGoodSurPctTime                  = 0.0;

static ArrayList g_FlowBuckets[FLOW_BUCKETS];
static bool      g_BucketsReady = false;

static ArrayList g_AreaCX       = null;
static ArrayList g_AreaCY       = null;
static ArrayList g_AreaPct      = null;

float            fNavBucketAssignRadius;
bool             bNavCacheEnable;
ConVar           VsBossFlowBuffer;
bool             bNavBucketMapInvalid;
int              iSiLimit;

#define PI                 3.1415926535
#define SEP_TTL            3.0

#define SEP_RADIUS         80.0
#define NAV_CD_SECS        0.5

#define PEN_LIMIT_SCALE_HI 1.00
#define PEN_LIMIT_SCALE_LO 0.50
#define PEN_LIMIT_MINL     1
#define PEN_LIMIT_MAXL     16

ArrayList lastSpawns = null;

#define RING_SLACK 350.0

bool      bSurFlowFallback;
float     fSurFlowFallbackTTL;

float     g_fMapMaxFlow = 0.0;

methodmap TheNavAreas
{

public     int Count()
    {
        EnsureNavAreasCache();
        return g_NavAreasCacheCount;
    }

public     Address GetAreaByIndex(int i)
    {
        EnsureNavAreasCache();
        if (i < 0 || i >= g_NavAreasCacheCount)
            return Address_Null;
        return g_AllNavAreasCache.Get(i);
    }
}

methodmap NavArea
{

public     bool IsNull()
    {
        return view_as<Address>(this) == Address_Null;
    }

public     void GetRandomPoint(float outPos[3])
    {
        L4D_FindRandomSpot(view_as<int>(this), outPos);
    }

    property int SpawnAttributes
    {

public         get()
        {
            return L4D_GetNavArea_SpawnAttributes(view_as<Address>(this));
        }

public         set(int v)
        {
            L4D_SetNavArea_SpawnAttributes(view_as<Address>(this), v);
        }
    }

public     float GetFlow()
    {
        return L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(this));
    }
}

enum
{
    TERROR_NAV_EMPTY             = 1 << 1,
    TERROR_NAV_STOP_SCAN         = 1 << 2,
    TERROR_NAV_BATTLESTATION     = 1 << 5,
    TERROR_NAV_FINALE            = 1 << 6,
    TERROR_NAV_PLAYER_START      = 1 << 7,
    TERROR_NAV_BATTLEFIELD       = 1 << 8,
    TERROR_NAV_IGNORE_VISIBILITY = 1 << 9,
    TERROR_NAV_NOT_CLEARABLE     = 1 << 10,
    TERROR_NAV_CHECKPOINT        = 1 << 11,
    TERROR_NAV_OBSCURED          = 1 << 12,
    TERROR_NAV_NO_MOBS           = 1 << 13,
    TERROR_NAV_THREAT            = 1 << 14,
    TERROR_NAV_RESCUE_VEHICLE    = 1 << 15,
    TERROR_NAV_RESCUE_CLOSET     = 1 << 16,
    TERROR_NAV_ESCAPE_ROUTE      = 1 << 17,
    TERROR_NAV_DOOR              = 1 << 18,
    TERROR_NAV_NOTHREAT          = 1 << 19
}

static StringMap g_PathCacheRes = null;

enum SIClass
{
    SI_None    = 0,
    SI_Smoker  = 1,
    SI_Boomer  = 2,
    SI_Hunter  = 3,
    SI_Spitter = 4,
    SI_Jockey  = 5,
    SI_Charger = 6
};

bool bPathCacheEnable;

public Plugin myinfo =
{
    name        = "Smart Director",
    author      = "Sion Gemini",
    description = "No Warnings + Bitwise Optimized",
    version     = "22.0",
    url         = "https:// steamcommunity.com/profiles/76561199209427576"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_bLateLoad = late;
    CreateNative("SD_API_SetMaxSpecials", Native_SetMaxSpecials);
    CreateNative("SD_API_SetSpawnInterval", Native_SetSpawnInterval);
    CreateNative("SD_API_SetSpawnDistance", Native_SetSpawnDistance);
    CreateNative("SD_API_SetTankControl", Native_SetTankControl);
    CreateNative("SD_API_SetHungerCooldown", Native_SetHungerCooldown);
    CreateNative("SD_API_SetSuperMode", Native_SetSuperMode);

    CreateNative("SD_API_SetCullDistance", Native_SetCullDistance);

    RegPluginLibrary("smart_director");
    return APLRes_Success;
}

public int Native_SetSuperMode(Handle plugin, int numParams)
{
    bool enable = view_as<bool>(GetNativeCell(1));

    if (g_bSuperMode != enable)
    {
        g_bSuperMode = enable;

        if (enable)
        {
            g_cvMaxSI.SetInt(24);
            PrintToChatAll("\x04[Sion]\x01 外部指令：已激活 \x03[超多特模式] \x01(上限自动锁定: \x0324\x01)");
            PrintToChatAll("\x04[配置]\x01 严格限制：25%%牛 20%%HT 20%%猴 15%%舌");
        }
        else {
            g_cvMaxSI.SetInt(8);
            PrintToChatAll("\x04[Sion]\x01 外部指令：已关闭超多特模式 \x01(上限恢复: \x038\x01)");
        }

        UnlockLimits();
    }
    return 1;
}

public int Native_SetCullDistance(Handle plugin, int numParams)
{
    float dist = GetNativeCell(1);
    if (dist < 500.0) dist = 500.0;
    g_cvCullDistance.SetFloat(dist);
    PrintToChatAll("\x04[Sion]\x01 外部指令: 自动处死距离已更新为 \x03%.0f 码", dist);
    return 1;
}

public int Native_SetHungerCooldown(Handle plugin, int numParams)
{
    float cooldown = GetNativeCell(1);

    if (cooldown < 1.0) cooldown = 0.1;

    g_cvHungerCooldown.SetFloat(cooldown);
    PrintToChatAll("\x04[Sion]\x01 外部指令: 补货冷却已更新为 \x03%.1f秒", cooldown);
    return 1;
}

public int Native_SetTankControl(Handle plugin, int numParams)
{
    bool enable = view_as<bool>(GetNativeCell(1));
    g_cvEnableTankControl.SetInt(enable ? 1 : 0);
    if (!enable) PrintToChatAll("\x04[Sion]\x01 外部指令: Tank生成已切换为 \x03[原生导演]");
    else PrintToChatAll("\x04[Sion]\x01 外部指令: Tank生成已切换为 \x03[插件接管]");
    return 1;
}

public int Native_SetMaxSpecials(Handle plugin, int numParams)
{
    int amount = GetNativeCell(1);
    if (amount < 0) amount = 0;
    if (amount > 32) amount = 32;

    g_cvMaxSI.SetInt(amount);
    UnlockLimits();

    PrintToChatAll("\x04[Sion]\x01 外部指令: 特感上限已更新为 \x03%d", amount);
    return 1;
}

public int Native_SetSpawnInterval(Handle plugin, int numParams)
{
    float interval = GetNativeCell(1);
    if (interval < 0.1) interval = 0.1;
    g_cvHungerCooldown.SetFloat(interval);
    PrintToChatAll("\x04[Sion]\x01 外部指令: 刷新间隔已更新为 \x03%.1f秒", interval);
    return 1;
}

public int Native_SetSpawnDistance(Handle plugin, int numParams)
{
    float min = GetNativeCell(1);
    float max = GetNativeCell(2);
    if (min < 0.0) min = 100.0;
    if (max < min) max = min + 100.0;
    g_cvSpawnDistMin.SetFloat(min);
    g_cvSpawnDistMax.SetFloat(max);
    UnlockLimits();
    PrintToChatAll("\x04[Sion]\x01 外部指令: 生成距离已更新为 \x03%.0f - %.0f", min, max);
    return 1;
}

// 释放当前地图的 Nav 分桶。
static void ClearNavBuckets()
{
    for (int i = 0; i < FLOW_BUCKETS; i++)
    {
        if (g_FlowBuckets[i] != null)
        {
            delete g_FlowBuckets[i];
            g_FlowBuckets[i] = null;
        }
        g_BucketMinZ[i] = 0.0;
        g_BucketMaxZ[i] = 0.0;
    }

    if (g_AreaZCore != null)
    {
        delete g_AreaZCore;
        g_AreaZCore = null;
    }
    if (g_AreaZMin != null)
    {
        delete g_AreaZMin;
        g_AreaZMin = null;
    }
    if (g_AreaZMax != null)
    {
        delete g_AreaZMax;
        g_AreaZMax = null;
    }
    if (g_AreaCX != null)
    {
        delete g_AreaCX;
        g_AreaCX = null;
    }
    if (g_AreaCY != null)
    {
        delete g_AreaCY;
        g_AreaCY = null;
    }
    if (g_AreaPct != null)
    {
        delete g_AreaPct;
        g_AreaPct = null;
    }
}
static void BuildNavIdIndexMap()
{
    if (g_NavIdToIndex != null)
    {
        delete g_NavIdToIndex;
        g_NavIdToIndex = null;
    }
    g_NavIdToIndex = new StringMap();

    EnsureNavAreasCache();

    for (int i = 0; i < g_NavAreasCacheCount; i++)
    {
        Address area  = g_AllNavAreasCache.Get(i);
        int     navid = L4D_GetNavAreaID(area);
        if (navid < 0) continue;

        char key[16];
        IntToString(navid, key, sizeof key);
        g_NavIdToIndex.SetValue(key, view_as<any>(i));
    }
}

stock void EnsureNavAreasCache()
{
    if (g_AllNavAreasCache == null)
    {
        g_AllNavAreasCache = new ArrayList();
        L4D_GetAllNavAreas(g_AllNavAreasCache);
        g_NavAreasCacheCount = g_AllNavAreasCache.Length;

    }
}

static void BuildNavBuckets()
{
    g_fMapMaxFlow = L4D2Direct_GetMapMaxFlowDistance();

    if (TryLoadBucketsFromCache())
        return;

    ClearNavBuckets();
    BuildNavIdIndexMap();
    EnsureNavAreasCache();

    int   iAreaCount      = g_NavAreasCacheCount;
    float fMapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();

    g_AreaZCore           = new ArrayList();
    g_AreaZMin            = new ArrayList();
    g_AreaZMax            = new ArrayList();
    g_AreaCX              = new ArrayList();
    g_AreaCY              = new ArrayList();
    g_AreaPct             = new ArrayList();

    for (int i = 0; i < iAreaCount; i++)
    {
        g_AreaZCore.Push(0.0);
        g_AreaZMin.Push(0.0);
        g_AreaZMax.Push(0.0);
        g_AreaCX.Push(0.0);
        g_AreaCY.Push(0.0);
        g_AreaPct.Push(-1);
    }

    for (int b = 0; b < FLOW_BUCKETS; b++)
    {
        g_FlowBuckets[b] = null;
        g_BucketMinZ[b]  = 1.0e9;
        g_BucketMaxZ[b]  = -1.0e9;
    }

    ArrayList badIdxs   = new ArrayList();
    ArrayList validIdxs = new ArrayList();

    for (int i = 0; i < iAreaCount; i++)
    {
        Address areaAddr = g_AllNavAreasCache.Get(i);
        if (areaAddr == Address_Null) continue;

        NavArea pArea = view_as<NavArea>(areaAddr);

        float   cx, cy, zAvg, zMin, zMax;
        SampleAreaCenterAndZ(areaAddr, cx, cy, zAvg, zMin, zMax, 3);
        g_AreaCX.Set(i, cx);
        g_AreaCY.Set(i, cy);
        g_AreaZCore.Set(i, zAvg);
        g_AreaZMin.Set(i, zMin);
        g_AreaZMax.Set(i, zMax);

        float fFlow  = pArea.GetFlow();
        bool  flowOK = (fFlow >= 0.0 && fFlow <= fMapMaxFlowDist);

        if (flowOK)
        {
            int percent = FlowDistanceToPercent(fFlow);
            if (percent < 0) percent = 0;
            if (percent > 100) percent = 100;

            if (g_FlowBuckets[percent] == null)
                g_FlowBuckets[percent] = new ArrayList();
            g_FlowBuckets[percent].Push(i);

            if (zMin < g_BucketMinZ[percent]) g_BucketMinZ[percent] = zMin;
            if (zMax > g_BucketMaxZ[percent]) g_BucketMaxZ[percent] = zMax;

            g_AreaPct.Set(i, percent);
            validIdxs.Push(i);
        }
        else
        {
            badIdxs.Push(i);
        }
    }

    if (validIdxs.Length > 0 && badIdxs.Length > 0)
    {

        int         B = badIdxs.Length, V = validIdxs.Length;
        float       estCostM    = float(B) * float(V) / 1.0e6;
        const float hardCostM   = 5.0;
        const float timeBudgetS = 0.60;

        float       t1          = GetEngineTime();
        if (estCostM > hardCostM)
        {

        }
        else
        {

            const float cell   = 2000.0;
            float       radius = fNavBucketAssignRadius;
            if (radius < 0.0) radius = 0.0;

            StringMap cellMap    = new StringMap();
            ArrayList ownedLists = new ArrayList();

            for (int i = 0; i < V; i++)
            {
                int   vidx = validIdxs.Get(i);
                float vx   = view_as<float>(g_AreaCX.Get(vidx));
                float vy   = view_as<float>(g_AreaCY.Get(vidx));
                int   cx   = RoundToFloor(vx / cell);
                int   cy   = RoundToFloor(vy / cell);

                char  key[32];
                Format(key, sizeof key, "%d,%d", cx, cy);

                any       h;
                ArrayList lst;
                if (!cellMap.GetValue(key, h))
                {
                    lst = new ArrayList();
                    ownedLists.Push(lst);
                    cellMap.SetValue(key, view_as<any>(lst));
                }
                else
                {
                    lst = view_as<ArrayList>(h);
                }
                lst.Push(vidx);
            }

            int maxLayer = (radius > 0.1) ? RoundToCeil(radius / cell) : 6;
            if (maxLayer < 0) maxLayer = 0;
            if (maxLayer > 48) maxLayer = 48;
            float r2     = (radius > 0.1) ? (radius * radius) : -1.0;

            int   mapped = 0, dropped = 0;

            for (int bi = 0; bi < B; bi++)
            {

                if ((bi & 1023) == 0)
                {
                    float el = GetEngineTime() - t1;
                    if (el > timeBudgetS)
                    {

                        break;
                    }
                }

                int   aidx   = badIdxs.Get(bi);
                float ax     = view_as<float>(g_AreaCX.Get(aidx));
                float ay     = view_as<float>(g_AreaCY.Get(aidx));
                int   acx    = RoundToFloor(ax / cell);
                int   acy    = RoundToFloor(ay / cell);

                float bestD2 = 1.0e20;
                int   bestV  = -1;

                for (int layer = 0; layer <= maxLayer; layer++)
                {
                    bool foundThisRing = false;
                    int  minX = acx - layer, maxX = acx + layer;
                    int  minY = acy - layer, maxY = acy + layer;

                    for (int cy = minY; cy <= maxY; cy++)
                    {
                        for (int cx = minX; cx <= maxX; cx++)
                        {
                            bool onEdge = (cx == minX || cx == maxX || cy == minY || cy == maxY);
                            if (!onEdge) continue;

                            char key[32];
                            Format(key, sizeof key, "%d,%d", cx, cy);

                            any h;
                            if (!cellMap.GetValue(key, h)) continue;
                            ArrayList lst = view_as<ArrayList>(h);

                            for (int k = 0; k < lst.Length; k++)
                            {
                                int   vidx = lst.Get(k);
                                float vx   = view_as<float>(g_AreaCX.Get(vidx));
                                float vy   = view_as<float>(g_AreaCY.Get(vidx));
                                float dx = ax - vx, dy = ay - vy;
                                float d2 = dx * dx + dy * dy;

                                if (r2 > 0.0 && d2 > r2) continue;
                                if (d2 < bestD2)
                                {
                                    bestD2        = d2;
                                    bestV         = vidx;
                                    foundThisRing = true;
                                }
                            }
                        }
                    }

                    if (foundThisRing)
                        break;
                }

                if (bestV != -1)
                {
                    int percent = view_as<int>(g_AreaPct.Get(bestV));
                    if (percent < 0) percent = 0;
                    if (percent > 100) percent = 100;

                    if (g_FlowBuckets[percent] == null)
                        g_FlowBuckets[percent] = new ArrayList();
                    g_FlowBuckets[percent].Push(aidx);

                    float zmin = view_as<float>(g_AreaZMin.Get(aidx));
                    float zmax = view_as<float>(g_AreaZMax.Get(aidx));
                    if (zmin < g_BucketMinZ[percent]) g_BucketMinZ[percent] = zmin;
                    if (zmax > g_BucketMaxZ[percent]) g_BucketMaxZ[percent] = zmax;

                    g_AreaPct.Set(aidx, percent);
                    mapped++;
                }
                else
                {
                    dropped++;
                }

            }

            for (int i = 0; i < ownedLists.Length; i++)
            {
                ArrayList lst = ownedLists.Get(i);
                if (lst != null) delete lst;
            }
            delete ownedLists;
            delete cellMap;
        }
    }
    else
    {

    }

    g_BucketsReady = true;

    SaveBucketsToCache();
}
static void SaveBucketsToCache()
{
    if (!bNavCacheEnable || !g_BucketsReady) return;

    MakeBucketCachePath();

    KeyValues kv = new KeyValues("BucketsCache");
    kv.SetString("version", BUCKET_CACHE_VER);

    char map[64];
    GetCurrentMap(map, sizeof map);
    kv.SetString("map", map);

    EnsureNavAreasCache();
    int areaCount = g_NavAreasCacheCount;

    kv.SetNum("area_count", areaCount);
    kv.SetFloat("max_flow", L4D2Direct_GetMapMaxFlowDistance());
    kv.SetFloat("vsboss_buffer", VsBossFlowBuffer.FloatValue);
    kv.SetNum("map_invalid", bNavBucketMapInvalid ? 1 : 0);
    kv.SetFloat("assign_radius", fNavBucketAssignRadius);

    kv.JumpToKey("bucket_zrange", true);
    for (int b = 0; b <= 100; b++)
    {
        char k[8];
        IntToString(b, k, sizeof k);
        kv.JumpToKey(k, true);
        kv.SetFloat("min", g_BucketMinZ[b]);
        kv.SetFloat("max", g_BucketMaxZ[b]);
        kv.GoBack();
    }
    kv.GoBack();

    kv.JumpToKey("areas", true);
    for (int i = 0; i < areaCount; i++)
    {
        int navid = GetNavIDByIndex(i);
        if (navid < 0) continue;

        int bucket = view_as<int>(g_AreaPct.Get(i));
        if (bucket < 0 || bucket > 100) continue;

        char sNav[16];
        IntToString(navid, sNav, sizeof sNav);
        kv.JumpToKey(sNav, true);

        kv.SetNum("bucket", bucket);
        kv.SetFloat("cx", view_as<float>(g_AreaCX.Get(i)));
        kv.SetFloat("cy", view_as<float>(g_AreaCY.Get(i)));
        kv.SetFloat("zCore", view_as<float>(g_AreaZCore.Get(i)));
        kv.SetFloat("zMin", view_as<float>(g_AreaZMin.Get(i)));
        kv.SetFloat("zMax", view_as<float>(g_AreaZMax.Get(i)));

        kv.GoBack();
    }
    kv.GoBack();

    kv.ExportToFile(g_sBucketCachePath);
    delete kv;

}

static int FlowDistanceToPercent(float flowDist)
{
    float maxd = L4D2Direct_GetMapMaxFlowDistance();
    if (maxd <= 1.0) maxd = 1.0;

    float d = flowDist;
    if (!(d >= 0.0)) d = 0.0;
    if (d > maxd) d = maxd;

    float prox = d + VsBossFlowBuffer.FloatValue;
    if (!(prox >= 0.0)) prox = 0.0;
    if (prox > maxd) prox = maxd;

    return RoundToNearest((prox / maxd) * 100.0);
}

static void SampleAreaCenterAndZ(Address areaAddr, float &cx, float &cy, float &zAvg, float &zMin, float &zMax, int samples = 3)
{
    cx = cy = 0.0;
    zAvg    = 0.0;
    zMin    = 1.0e9;
    zMax    = -1.0e9;
    if (areaAddr == Address_Null || samples <= 0)
    {
        zMin = zMax = zAvg = 0.0;
        return;
    }

    NavArea area = view_as<NavArea>(areaAddr);
    float   p[3];

    for (int i = 0; i < samples; i++)
    {
        area.GetRandomPoint(p);
        cx += p[0];
        cy += p[1];
        zAvg += p[2];
        if (p[2] < zMin) zMin = p[2];
        if (p[2] > zMax) zMax = p[2];
    }
    float inv = 1.0 / float(samples);
    cx *= inv;
    cy *= inv;
    zAvg *= inv;
}
static bool TryLoadBucketsFromCache()
{
    MakeBucketCachePath();
    if (!FileExists(g_sBucketCachePath)) return false;

    KeyValues kv = new KeyValues("BucketsCache");
    if (!kv.ImportFromFile(g_sBucketCachePath))
    {
        delete kv;
        return false;
    }

    kv.Rewind();
    char ver[64];
    kv.GetString("version", ver, sizeof ver, "");
    if (!StrEqual(ver, BUCKET_CACHE_VER))
    {
        delete kv;
        return false;
    }

    char map[64], mapCur[64];
    GetCurrentMap(mapCur, sizeof mapCur);
    kv.GetString("map", map, sizeof map, "");
    if (!StrEqual(map, mapCur))
    {
        delete kv;
        return false;
    }

    EnsureNavAreasCache();
    int currentAreaCount = g_NavAreasCacheCount;

    int areaCount        = kv.GetNum("area_count", -1);
    if (areaCount <= 0 || areaCount != currentAreaCount)
    {
        delete kv;
        return false;
    }

    float maxFlowCur    = L4D2Direct_GetMapMaxFlowDistance();
    float maxFlowCached = kv.GetFloat("max_flow", -1.0);
    if (FloatAbs(maxFlowCached - maxFlowCur) > 0.1)
    {
        delete kv;
        return false;
    }

    float bufCur        = VsBossFlowBuffer.FloatValue;
    float bufCached     = kv.GetFloat("vsboss_buffer", 0.0);
    int   mapInvalidCur = bNavBucketMapInvalid ? 1 : 0;
    int   mapInvalidCac = kv.GetNum("map_invalid", 1);
    float assignRcur    = fNavBucketAssignRadius;
    float assignRcac    = kv.GetFloat("assign_radius", 0.0);

    if (FloatAbs(bufCur - bufCached) > 0.01 || mapInvalidCur != mapInvalidCac || FloatAbs(assignRcur - assignRcac) > 0.5)
    {
        delete kv;
        return false;
    }

    ClearNavBuckets();
    BuildNavIdIndexMap();

    g_AreaZCore = new ArrayList();
    g_AreaZMin  = new ArrayList();
    g_AreaZMax  = new ArrayList();
    g_AreaCX    = new ArrayList();
    g_AreaCY    = new ArrayList();
    g_AreaPct   = new ArrayList();

    for (int i = 0; i < areaCount; i++)
    {
        g_AreaZCore.Push(0.0);
        g_AreaZMin.Push(0.0);
        g_AreaZMax.Push(0.0);
        g_AreaCX.Push(0.0);
        g_AreaCY.Push(0.0);
        g_AreaPct.Push(-1);
    }

    for (int b = 0; b < FLOW_BUCKETS; b++)
    {
        g_BucketMinZ[b] = 1.0e9;
        g_BucketMaxZ[b] = -1.0e9;
    }

    if (kv.JumpToKey("bucket_zrange", false))
    {
        for (int b = 0; b <= 100; b++)
        {
            char k[8];
            IntToString(b, k, sizeof k);
            if (kv.JumpToKey(k, false))
            {
                g_BucketMinZ[b] = kv.GetFloat("min", 0.0);
                g_BucketMaxZ[b] = kv.GetFloat("max", 0.0);
                kv.GoBack();
            }
        }
        kv.GoBack();
    }

    if (!kv.JumpToKey("areas", false))
    {
        delete kv;
        return false;
    }

    if (kv.GotoFirstSubKey(false))
    {
        do
        {
            char sNav[16];
            kv.GetSectionName(sNav, sizeof sNav);
            int navid = StringToInt(sNav);
            int idx   = GetAreaIndexByNavID_Int(navid);
            if (idx < 0) continue;

            int bucket = kv.GetNum("bucket", -1);
            if (bucket < 0 || bucket > 100) continue;

            float cx   = kv.GetFloat("cx", 0.0);
            float cy   = kv.GetFloat("cy", 0.0);
            float zc   = kv.GetFloat("zCore", 0.0);
            float zmin = kv.GetFloat("zMin", 0.0);
            float zmax = kv.GetFloat("zMax", 0.0);

            g_AreaCX.Set(idx, cx);
            g_AreaCY.Set(idx, cy);
            g_AreaZCore.Set(idx, zc);
            g_AreaZMin.Set(idx, zmin);
            g_AreaZMax.Set(idx, zmax);
            g_AreaPct.Set(idx, bucket);

            if (g_FlowBuckets[bucket] == null)
                g_FlowBuckets[bucket] = new ArrayList();
            g_FlowBuckets[bucket].Push(idx);
        }
        while (kv.GotoNextKey(false));
        kv.GoBack();
    }

    delete kv;
    g_BucketsReady = true;

    return true;
}
static int GetAreaIndexByNavID_Int(int navid)
{
    if (g_NavIdToIndex == null) BuildNavIdIndexMap();
    char key[16];
    IntToString(navid, key, sizeof key);
    any idx;
    return g_NavIdToIndex.GetValue(key, idx) ? view_as<int>(idx) : -1;
}

static void MakeBucketCachePath()
{
    char map[64];
    GetCurrentMap(map, sizeof map);
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof dir, "data/infd_buckets");
    CreateDirectory(dir, 511);
    BuildPath(Path_SM, g_sBucketCachePath, sizeof g_sBucketCachePath, "data/infd_buckets/%s.kv", map);
}

stock bool TryGetLowestSurvivorFootZ(float &outMinZ)
{
    bool  found = false;
    float bestZ = 0.0;
    float s[3];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvFast(i) || !IsAlive(i))
            continue;

        GetClientAbsOrigin(i, s);
        if (!found || s[2] < bestZ)
        {
            bestZ = s[2];
            found = true;
        }
    }

    if (found) outMinZ = bestZ;
    return found;
}
static void OnFlowBufferChanged(ConVar convar, const char[] ov, const char[] nv)
{

    RebuildNavBuckets();
}
static void RebuildNavBuckets()
{
    BuildNavBuckets();
}

static bool IsFlowAbnormal(float flowDist, float maxFlow)
{
    if (maxFlow <= 0.0) return true;
    return (flowDist < 0.0 || flowDist > maxFlow);
}

static bool TryGetClientFlowDistanceSafe(int client, float &outFlow)
{
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();

    float d       = L4D2Direct_GetFlowDistance(client);
    if (!IsFlowAbnormal(d, maxFlow))
    {
        outFlow = d;
        return true;
    }

    Address last = view_as<Address>(L4D_GetLastKnownArea(client));
    if (TryGetFlowDistanceFromArea(last, outFlow)) return true;

    float pos[3];
    GetClientAbsOrigin(client, pos);
    Address near = L4D_GetNearestNavArea(pos, 300.0, false, false, false, TEAM_SURVIVOR);
    if (TryGetFlowDistanceFromArea(near, outFlow)) return true;

    return false;
}
static bool TryGetFlowDistanceFromArea(Address area, float &outFlow)
{
    if (area == Address_Null) return false;
    float d       = L4D2Direct_GetTerrorNavAreaFlow(area);
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (IsFlowAbnormal(d, maxFlow)) return false;
    outFlow = d;
    return true;
}

static bool TryGetClientFlowPercentSafe(int client, int &outPct)
{
    float d;
    if (!TryGetClientFlowDistanceSafe(client, d)) return false;
    outPct = FlowDistanceToPercent(d);
    if (outPct < 0) outPct = 0;
    if (outPct > 100) outPct = 100;
    return true;
}

static int GetHighestFlowSurvivorSafe()
{
    int best = -1, bestPct = -1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvFast(i)) continue;
        int pct;
        if (!TryGetClientFlowPercentSafe(i, pct)) continue;
        if (pct > bestPct)
        {
            bestPct = pct;
            best    = i;
        }
    }
    if (best != -1) return best;

    return L4D_GetHighestFlowSurvivor();
}

static int CountAliveSurvivors()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvFast(i))
            n++;
    return n;
}

static float SD_GetDynamicCooldown()
{
    float baseCooldown = g_cvHungerCooldown.FloatValue;

    int   standing     = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvFast(i) && !g_bIsIncap[i])
            standing++;
    }
    int   alive = standing;

    float scale;
    switch (alive)
    {
        case 0: scale = 0.30;
        case 1: scale = 0.30;
        case 2: scale = 0.50;
        case 3: scale = 0.70;
        default: scale = 1.00;
    }

    float result = baseCooldown * scale;

    return result;
}

stock float clamp(float val, float min, float max)
{
    if (val < min) return min;
    if (val > max) return max;
    return val;
}
stock int clampi(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static int BuildBucketOrder(int s, int win, bool includeCenter, int outBuckets[FLOW_BUCKETS])
{
    s     = clampi(s, 0, 100);
    win   = clampi(win, 0, 100);

    int n = 0;
    if (includeCenter)
        outBuckets[n++] = s;

    int fdist   = 1;
    int bdist   = 1;

    int fwdRun  = 2;
    int backRun = 1;

    int addedF  = 0;
    int addedB  = 0;

    while ((fdist <= win || bdist <= win) && n < FLOW_BUCKETS)
    {

        int pushedF = 0;
        for (int k = 0; k < fwdRun && fdist <= win && n < FLOW_BUCKETS; k++, fdist++)
        {
            int b = s + fdist;
            if (b <= 100)
            {
                outBuckets[n++] = b;
                pushedF++;
            }
        }
        addedF += pushedF;

        int pushedB = 0;
        for (int k = 0; k < backRun && bdist <= win && n < FLOW_BUCKETS; k++, bdist++)
        {
            int a = s - bdist;
            if (a >= 0)
            {
                outBuckets[n++] = a;
                pushedB++;
            }
        }
        addedB += pushedB;

        if ((addedF - addedB) > 4)
        {
            fwdRun++;
            backRun++;
        }
    }
    return n;
}

stock bool IsNavOnCooldown(int areaIdx, float now)
{
    return IsNavOnCooldownID(GetNavIDByIndex(areaIdx), now);
}
stock void TouchNavCooldown(int areaIdx, float now, float cooldown = 8.0)
{
    TouchNavCooldownID(GetNavIDByIndex(areaIdx), now, cooldown);
}
void TouchNavCooldownID(int areaID, float now, float cooldown = 8.0)
{
    if (areaID < 0) return;
    if (g_NavCooldown == null) g_NavCooldown = new StringMap();

    char key[16];
    IntToString(areaID, key, sizeof key);
    g_NavCooldown.SetValue(key, view_as<any>(now + cooldown));
}

bool IsNavOnCooldownID(int areaID, float now)
{
    if (areaID < 0 || g_NavCooldown == null) return false;

    char key[16];
    IntToString(areaID, key, sizeof key);

    any stored;
    if (g_NavCooldown.GetValue(key, stored))
    {
        float until = view_as<float>(stored);
        return (now < until);
    }
    return false;
}
stock int GetNavIDByIndex(int idx)
{
    EnsureNavAreasCache();

    if (idx < 0 || idx >= g_NavAreasCacheCount)
        return -1;

    Address area = g_AllNavAreasCache.Get(idx);
    return L4D_GetNavAreaID(area);
}

stock float PenLimitScale()
{

    float L = float(iSiLimit);
    float t = Clamp01((L - float(PEN_LIMIT_MINL)) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL));

    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}

stock bool PassMinSeparation(const float pos[3])
{
    if (lastSpawns == null || lastSpawns.Length == 0) return true;

    float now            = GetGameTime();
    float k              = PenLimitScale();
    float SEP_RADIUS_EFF = SEP_RADIUS * k;
    float sep2           = SEP_RADIUS_EFF * SEP_RADIUS_EFF;

    for (int i = lastSpawns.Length - 1; i >= 0; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec);

        if (now - rec[3] > SEP_TTL)
        {
            lastSpawns.Erase(i);
            continue;
        }

        float rec3[3];
        rec3[0] = rec[0];
        rec3[1] = rec[1];
        rec3[2] = rec[2];

        if (GetVectorDistance(pos, rec3, true) < sep2)
            return false;
    }
    return true;
}

stock int GetPositionBucketPercent(float pos[3])
{

    Address nav = L4D2Direct_GetTerrorNavArea(pos);
    if (nav == Address_Null)
        nav = L4D_GetNearestNavArea(pos, 300.0, false, false, false, TEAM_INFECTED);

    if (nav == Address_Null) return -1;

    int navid   = L4D_GetNavAreaID(nav);
    int areaIdx = GetAreaIndexByNavID_Int(navid);

    if (areaIdx < 0 || areaIdx >= g_AreaPct.Length)
        return -1;

    int bucket = view_as<int>(g_AreaPct.Get(areaIdx));
    return (bucket >= 0 && bucket <= 100) ? bucket : -1;
}

static bool GetFallbackSurPct(int &outPct)
{
    if (!bSurFlowFallback) return false;
    if (g_LastGoodSurPct < 0) return false;
    float now = GetGameTime();
    if ((now - g_LastGoodSurPctTime) > fSurFlowFallbackTTL) return false;
    outPct = g_LastGoodSurPct;
    return true;
}

stock bool PassRealPositionCheck(float candPos[3], int targetSur, int si = 0)
{

    int candPercent = GetPositionBucketPercent(candPos);
    if (candPercent < 0)
        return true;

    int surPercent = -1;
    if (IsValidSurvFast(targetSur) && IsAlive(targetSur))
    {
        if (!TryGetClientFlowPercentSafe(targetSur, surPercent))
            surPercent = -1;
    }
    else
    {
        int fb = GetHighestFlowSurvivorSafe();
        if (!IsValidSurvFast(fb) || !TryGetClientFlowPercentSafe(fb, surPercent))
            surPercent = -1;
    }

    if (surPercent < 0)
    {
        int fpct;
        if (GetFallbackSurPct(fpct))
            surPercent = fpct;
    }

    if (candPercent < surPercent - 6)
        return false;

    float minFootZ;
    if (TryGetLowestSurvivorFootZ(minFootZ))
    {

        if (candPercent < surPercent && (candPos[2] <= (minFootZ - 180.0) || (si != view_as<int>(SI_Smoker) && candPos[2] >= (minFootZ + 200.0))))
            return false;
    }

    return true;
}
static bool WillStuck(const float at[3])
{
    static const float mins[3] = { -16.0, -16.0, 0.0 };
    static const float maxs[3] = { 16.0, 16.0, 71.0 };
    Handle             tr      = TR_TraceHullFilterEx(at, at, mins, maxs, MASK_PLAYERSOLID, TraceFilter_Stuck);
    bool               hit     = TR_DidHit(tr);
    delete tr;
    return hit;
}

public bool TraceFilter(int entity, int contentsMask)
{

    if (entity <= MaxClients) return false;
    if (!IsValidEntity(entity)) return false;

    static char cls[16];
    GetEntityClassname(entity, cls, sizeof(cls));

    if (cls[0] == 'i' && cls[1] == 'n') return false;
    if (cls[0] == 'w' && cls[1] == 'i') return false;

    return true;
}
stock bool TraceFilter_Stuck(int entity, int contentsMask)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
        return false;

    static char sClassName[20];
    GetEntityClassname(entity, sClassName, sizeof(sClassName));
    if (strcmp(sClassName, "env_physics_blocker") == 0 && !EnvBlockType(entity))
        return false;

    return true;
}
stock bool EnvBlockType(int entity)
{
    int BlockType = GetEntProp(entity, Prop_Data, "m_nBlockType");
    return !(BlockType == 1 || BlockType == 2);
}

static bool RayClear(const float src[3], const float dst[3], int mask)
{
    Handle tr = TR_TraceRayFilterEx(src, dst, mask, RayType_EndPoint, TraceFilter);
    bool   ok = (!TR_DidHit(tr) || TR_GetFraction(tr) >= 0.99);
    delete tr;
    return ok;
}
// 从 gamedata 加载特感数量补丁。
static void InitSDK_FromGamedata()
{
    char sBuffer[128];

    strcopy(sBuffer, sizeof(sBuffer), "function_data");
    GameData hGameData = new GameData(sBuffer);
    if (hGameData == null)
        SetFailState("Failed to load \"%s.txt\" gamedata.", sBuffer);

    strcopy(sBuffer, sizeof(sBuffer), "CDirector::GetMaxPlayerZombies");
    MemoryPatch mPatch = MemoryPatch.CreateFromConf(hGameData, sBuffer);
    if (!mPatch.Validate())
        SetFailState("Failed to verify patch: %s", sBuffer);
    if (!mPatch.Enable())
        SetFailState("Failed to Enable patch: %s", sBuffer);

    delete hGameData;
}

public Action Event_PlayerDeath_Kick(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == 3 && IsFakeClient(client))
    {

        CreateTimer(0.1, Timer_KickDeadBot, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Continue;
}

public Action Timer_KickDeadBot(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && !IsPlayerAlive(client))
    {

        KickClient(client, "Instant Cleanup");
    }
    return Plugin_Stop;
}

public void OnPluginStart()
{
    bNavCacheEnable = true;
    g_hSpawnQueue   = new ArrayList();
    InitSDK_FromGamedata();

    for (int i = 0; i < FLOW_BUCKETS; i++)
        g_FlowBuckets[i] = null;

    g_cvMaxSI              = CreateConVar("sd_max_si", "8", "同屏最大特感数量");
    g_cvDebugMode          = CreateConVar("sd_debug_mode", "0", "开启调试日志与连线 (1=开)");
    g_cvSpawnDistMin       = CreateConVar("sd_dist_min", "150.0", "最小生成距离");
    g_cvSpawnDistMax       = CreateConVar("sd_dist_max", "350.0", "最大生成距离");
    g_cvEnableTankControl  = CreateConVar("sd_enable_tank_control", "1", "是否开启插件接管Tank生成");
    g_cvCheckVis           = CreateConVar("sd_check_vis", "1", "视线检测模式: 0=关(暴力), 1=仅目标(推荐), 2=全队(严格)");
    g_cvCullDistance       = CreateConVar("sd_cull_dist", "1000.0", "特感落后多少码自动处死");
    g_cvTankChance         = CreateConVar("sd_tank_chance", "5", "Tank概率");
    g_cvPhantomChance      = CreateConVar("sd_phantom_chance", "20", "制造背后/头顶幻听的概率 (0-100)");
    g_cvmobcooldown        = CreateConVar("sd_mob_cooldown", "60", "刷新尸潮的间隔时间（秒）");
    g_cvHungerCooldown     = CreateConVar("sd_hunger_cooldown", "5.0", "刷新时间");
    g_cvLimitBatchHalf     = CreateConVar("sd_limit_batch_half", "1", "单次生成队列半数限制 (1=是)");
    g_cvSilentSI           = CreateConVar("sd_silent_si", "0", "独立选项: 是否开启忍者特感 (全局屏蔽特感叫声): 0=关, 1=开");
    g_cvPhantomMaxSounds   = CreateConVar("sd_phantom_max_sounds", "4", "触发幻听时，最多同时播放几条进攻声音 (建议 2-4)");

    g_cvDifficultyTier     = CreateConVar("sd_difficulty_tier", "2", "难度档位(1-6): 1=无尸潮, 2=标准, 3=进阶, 4=长尸潮, 5=地狱(克存活高压), 6=绝境(继承5档+特感无声+终点暴走)");
    g_cvPhantomIntervalMin = CreateConVar("sd_phantom_interval_min", "4.0", "随机幻听的最小触发间隔 (秒)");
    g_cvPhantomIntervalMax = CreateConVar("sd_phantom_interval_max", "15.0", "随机幻听的最大触发间隔 (秒)");
    g_cvDifficultyTier.AddChangeHook(OnTierVarChanged);

    AddNormalSoundHook(Hook_NormalSound);

    VsBossFlowBuffer = FindConVar("versus_boss_buffer");
    if (VsBossFlowBuffer != null)
    {
        VsBossFlowBuffer.AddChangeHook(OnFlowBufferChanged);
    }

    g_hGriefTargets = new ArrayList(ByteCountToCells(64));
    BuildPath(Path_SM, g_sGriefFilePath, sizeof(g_sGriefFilePath), "data/sd_grief_targets.txt");
    LoadGriefTargets();

    RegAdminCmd("sm_sd_grief", Cmd_ToggleGrief, ADMFLAG_ROOT, "开关指定玩家的贴脸刷怪模式");

    RegAdminCmd("sm_sd_rebuild_nav", Cmd_RebuildNav, ADMFLAG_ROOT, "强制重建Nav分桶");
    RegAdminCmd("sm_nd_flow", Cmd_NavDebugFlow, ADMFLAG_ROOT, "可视化 Nav 分桶流向 (画出通往终点的 Flow 路径)");

    RegAdminCmd("sm_nd", Cmd_NavDebug, ADMFLAG_ROOT, "调试当前位置的Nav和分桶信息");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("finale_vehicle_leaving", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("create_panic_event", Event_PanicEvent);

    HookEvent("player_incapacitated", Event_StatusChange);
    HookEvent("player_death", Event_StatusChange);
    HookEvent("survivor_rescued", Event_StatusChange);
    HookEvent("revive_success", Event_StatusChange);
    HookEvent("defibrillator_used", Event_StatusChange);
    HookEvent("player_now_it", Event_PlayerBiled);
    HookEvent("player_no_longer_it", Event_PlayerBiledEnd);
    HookEvent("lunge_pounce", Event_PinStart);
    HookEvent("pounce_end", Event_PinEnd);
    HookEvent("jockey_ride", Event_PinStart);
    HookEvent("jockey_ride_end", Event_PinEnd);
    HookEvent("charger_pummel_start", Event_PinStart);
    HookEvent("charger_pummel_end", Event_PinEnd);
    HookEvent("charger_carry_start", Event_PinStart);
    HookEvent("charger_carry_end", Event_PinEnd);
    HookEvent("tongue_grab", Event_PinStart);
    HookEvent("tongue_release", Event_PinEnd);
    HookEvent("choke_start", Event_PinStart);
    HookEvent("choke_end", Event_PinEnd);

    HookEvent("player_death", Event_PlayerDeath_Kick, EventHookMode_Pre);

    HookEvent("player_team", Event_CacheUpdate);
    HookEvent("player_spawn", Event_CacheUpdate_Spawn);
    HookEvent("player_death", Event_CacheUpdate);
    HookEvent("player_disconnect", Event_CacheUpdate_Disconnect);

    RegAdminCmd("sm_sd_force_spawn", Cmd_ForceSpawn, ADMFLAG_ROOT, "强制生成");
    RegAdminCmd("sm_sd_force_tank", Cmd_ForceTank, ADMFLAG_ROOT, "强制Tank封路测试");
    RegAdminCmd("sm_sd_rebuild_nav", Cmd_RebuildNav, ADMFLAG_ROOT, "强制重建Nav分桶");

    PrecacheSound("player/hunter/voice/attack/hunter_shriek_1.wav");
    PrecacheSound("player/boomer/voice/attack/boomer_attack_01.wav");
    PrecacheSound("player/smoker/voice/attack/smoker_attack_01.wav");
    PrecacheSound("player/jockey/voice/attack/jockey_attack_01.wav");
    PrecacheSound("player/charger/voice/attack/charger_charge_01.wav");

    ApplyOptimizations();
    if (g_bLateLoad)
    {
        BuildNavBuckets();
        for (int i = 1; i <= MaxClients; i++)
            UpdateClientCache(i);
        if (L4D_HasAnySurvivorLeftSafeArea())
        {
            UnlockLimits();
            L4D_OnFirstSurvivorLeftSafeArea_Post(0);
        }
    }
    else {
        LockLimits();
    }
}

public void OnPluginEnd()
{
    LockLimits();
    delete g_hSpawnQueue;
    ClearNavAreasCache();
}

public Action Event_PanicEvent(Event event, const char[] name, bool dontBroadcast)
{

    if (!g_bPanicMode)
    {
        g_fOriginalMinDist = g_cvSpawnDistMin.FloatValue;
        g_fOriginalMaxDist = g_cvSpawnDistMax.FloatValue;
    }

    g_bPanicMode = true;

    g_cvSpawnDistMin.SetFloat(100.0);
    g_cvSpawnDistMax.SetFloat(600.0);
    UnlockLimits();

    PrintToChatAll("\x04[Sion]\x01 : \x03尸潮爆发！\x01特感距离已压缩，AOE配额提升！");

    if (g_hPanicEndTimer != null) KillTimer(g_hPanicEndTimer);
    g_hPanicEndTimer = CreateTimer(10.0, Timer_EndPanicMode);

    return Plugin_Continue;
}

public Action Timer_EndPanicMode(Handle timer)
{
    g_bPanicMode     = false;
    g_hPanicEndTimer = null;

    g_cvSpawnDistMin.SetFloat(g_fOriginalMinDist);
    g_cvSpawnDistMax.SetFloat(g_fOriginalMaxDist);
    UnlockLimits();

    PrintToChatAll("\x04[Sion]\x01 : 尸潮消退，生成逻辑恢复正常。");
    return Plugin_Stop;
}

public void OnMapStart()
{
    LockLimits();
    ApplyOptimizations();
    CreateTimer(1.0, Timer_BuildNavBuckets_Delayed);
    BuildLogicCache();
    SD_ApplyTierSettings(g_cvDifficultyTier.IntValue);

}

public void OnMapEnd()
{
    ClearNavBuckets();

    ClearNavAreasCache();
}

stock void ClearNavAreasCache()
{
    if (g_AllNavAreasCache != null)
    {
        delete g_AllNavAreasCache;
        g_AllNavAreasCache   = null;
        g_NavAreasCacheCount = 0;

    }
}

public Action Cmd_RebuildNav(int client, int args)
{
    RebuildNavBuckets();
    ReplyToCommand(client, "[Smart Director] Nav Buckets Rebuilt.");
    return Plugin_Handled;
}

public Action Timer_BuildNavBuckets_Delayed(Handle timer)
{
    BuildNavBuckets();
    return Plugin_Continue;
}

bool SD_IsPosVisible(float pos[3], int target = 0)
{
    int mode = g_cvCheckVis.IntValue;
    if (mode == 0) return false;

    float checkPos[3];
    checkPos[0] = pos[0];
    checkPos[1] = pos[1];
    checkPos[2] = pos[2] + 50.0;

    if (mode == 1 && IsValidClient(target))
    {
        if (L4D2_IsVisibleToPlayer(target, TEAM_SURVIVOR, TEAM_INFECTED, 0, checkPos)) return true;
        return false;
    }

    for (int i = 1; i <= MaxClients; i++)
    {

        if (IsValidSurvFast(i))
        {
            if (L4D2_IsVisibleToPlayer(i, TEAM_SURVIVOR, TEAM_INFECTED, 0, checkPos)) return true;
        }
    }
    return false;
}
static bool IsPosVisibleSDK(float pos[3], bool teleportMode)
{
    float head[3];
    head[0] = pos[0];
    head[1] = pos[1];
    head[2] = pos[2] + 62.0;

    float chest[3];
    chest[0]            = pos[0];
    chest[1]            = pos[1];
    chest[2]            = pos[2] + 32.0;

    const int   visMask = (MASK_VISIBLE & MASK_SHOT);
    const float SIDE    = 16.0;

    int         effMode = 0;
    if (effMode == 2)
        effMode = (CountAliveSurvivors() > 4) ? 0 : 1;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvFast(i))
            continue;
        if (L4D_IsPlayerIncapacitated(i))
            continue;

        float eyes[3];
        GetClientEyePosition(i, eyes);

        if (effMode != 1 && RayClear(eyes, head, visMask))
            return true;

        if (effMode == 1)
        {
            float ang[3], fwd[3], right[3], up[3];
            GetClientEyeAngles(i, ang);
            GetAngleVectors(ang, fwd, right, up);

            float eyesL[3];
            eyesL[0] = eyes[0] - right[0] * SIDE;
            eyesL[1] = eyes[1] - right[1] * SIDE;
            eyesL[2] = eyes[2] - right[2] * SIDE;

            float eyesR[3];
            eyesR[0] = eyes[0] + right[0] * SIDE;
            eyesR[1] = eyes[1] + right[1] * SIDE;
            eyesR[2] = eyes[2] + right[2] * SIDE;

            if (RayClear(eyesL, head, visMask) || RayClear(eyesR, head, visMask))
                return true;
        }

        if (L4D2_IsVisibleToPlayer(i, TEAM_SURVIVOR, TEAM_INFECTED, 0, chest))
            return true;
    }

    return false;
}

bool SD_FindNavSpawnPos_Advanced(int targetClient, float minRange, float maxRange, bool reqVis, float outPos[3])
{
    if (!g_BucketsReady) return false;
    float targetPos[3];
    GetClientAbsOrigin(targetClient, targetPos);

    int targetPercent = 0;

    if (!TryGetClientFlowPercentSafe(targetClient, targetPercent))
    {

        int fpct;
        if (GetFallbackSurPct(fpct))
        {
            targetPercent = fpct;
        }
    }

    int searchBuckets[FLOW_BUCKETS];
    int bucketCount = 0;

    bucketCount     = BuildBucketOrder(targetPercent, 25, true, searchBuckets);

    for (int i = 0; i < bucketCount; i++)
    {
        int b = searchBuckets[i];
        if (g_BucketMaxZ[b] < targetPos[2] - 500.0 || g_BucketMinZ[b] > targetPos[2] + 500.0)
            continue;

        ArrayList bucket = g_FlowBuckets[b];
        if (bucket == null || bucket.Length == 0) continue;

        int count    = bucket.Length;
        int attempts = (count > 8) ? 8 : count;

        for (int k = 0; k < attempts; k++)
        {
            int     areaIdx  = bucket.Get(GetRandomInt(0, count - 1));
            Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
            if (areaAddr == Address_Null) continue;

            NavArea pArea = view_as<NavArea>(areaAddr);
            float   p[3];
            pArea.GetRandomPoint(p);

            float dist  = GetVectorDistance(targetPos, p);
            float slack = (p[2] > targetPos[2] + 100.0) ? 150.0 : 0.0;

            if (dist < minRange || dist > (maxRange + slack)) continue;
            if (WillStuck(p)) continue;
            if (reqVis && SD_IsPosVisible(p, targetClient)) continue;

            if (!PassMinSeparation(p)) continue;

            float zDiff     = FloatAbs(p[2] - targetPos[2]);
            float pathLimit = (dist * 1.5) + (zDiff * 2.5);

            if (PathPenalty_NoBuild(p, targetClient, pathLimit) != 0.0)
                continue;

            outPos = p;

            float record[4];
            record[0] = p[0];
            record[1] = p[1];
            record[2] = p[2];
            record[3] = GetGameTime();
            if (lastSpawns == null) lastSpawns = new ArrayList(4);
            lastSpawns.PushArray(record);

            return true;
        }
    }

    return false;
}

stock bool PathCache_TryGetSimple(const char[] key, bool &okOut)
{
    if (g_PathCacheRes == null) return false;
    any resAny;
    if (!g_PathCacheRes.GetValue(key, resAny)) return false;
    okOut = (view_as<int>(resAny) != 0);
    return true;
}
stock void PathCache_PutSimple(const char[] key, bool ok)
{
    if (g_PathCacheRes == null) return;
    g_PathCacheRes.SetValue(key, view_as<any>(ok ? 1 : 0));
}

stock float PathPenalty_NoBuild(const float candPos[3], int targetSur, float limitCost)
{
    int surv = -1;
    if (IsValidSurvFast(targetSur) && IsAlive(targetSur) && !L4D_IsPlayerIncapacitated(targetSur))
    {
        surv = targetSur;
    }
    else {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsValidSurvFast(i) && IsAlive(i) && !L4D_IsPlayerIncapacitated(i))
            {
                surv = i;
                break;
            }
        }
    }
    if (surv == -1) return PATH_NO_BUILD_PENALTY;

    float survPos[3];
    GetClientEyePosition(surv, survPos);
    survPos[2] -= 60.0;

    Address navGoal  = L4D_GetNearestNavArea(candPos, 120.0, false, false, false, TEAM_INFECTED);
    Address navStart = L4D_GetNearestNavArea(survPos, 120.0, false, false, false, TEAM_INFECTED);
    if (!navGoal || !navStart) return PATH_NO_BUILD_PENALTY;

    if (bPathCacheEnable)
    {
        char key[64];
        PathCache_BuildKey(navGoal, navStart, limitCost, key, sizeof key);
        bool okCached;
        if (PathCache_TryGetSimple(key, okCached))
            return okCached ? 0.0 : PATH_NO_BUILD_PENALTY;

        bool ok = L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false);
        PathCache_PutSimple(key, ok);
        return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
    }

    bool ok = L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false);
    return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
}

stock float ScaleNegativeOnly(float v, float k) { return (v < 0.0) ? (v * k) : v; }

stock void  PathCache_BuildKey(Address navGoal, Address navStart, float limitCost, char[] outKey, int maxlen)
{
    int idG = (navGoal != Address_Null) ? L4D_GetNavAreaID(navGoal) : -1;
    int idS = (navStart != Address_Null) ? L4D_GetNavAreaID(navStart) : -1;
    int q   = RoundToNearest(limitCost / fPathCacheQuantize);
    Format(outKey, maxlen, "%d|%d|%d", idG, idS, q);
}

void ApplyOptimizations()
{
    ConVar cvar;
    if ((cvar = FindConVar("g_ragdoll_maxcount")) != null) cvar.SetInt(0);
    if ((cvar = FindConVar("func_break_max_pieces")) != null) cvar.SetInt(0);
    if ((cvar = FindConVar("net_splitpacket_maxrate")) != null) cvar.SetInt(80000);
    if ((cvar = FindConVar("sv_minrate")) != null) cvar.SetInt(100000);
}

void UnlockLimits()
{

    int limit = g_cvMaxSI.IntValue;

    if (limit < 4) limit = 4;
    if (limit > 32) limit = 32;

    ConVar cvar;

    if ((cvar = FindConVar("z_max_player_zombies")) != null)
    {
        cvar.SetBounds(ConVarBound_Upper, true, 32.0);
        cvar.SetInt(limit);
    }
    if ((cvar = FindConVar("z_minion_limit")) != null) cvar.SetInt(limit);
    if ((cvar = FindConVar("survival_max_specials")) != null) cvar.SetInt(limit);

    int typeLimit   = g_bSuperMode ? limit : 4;
    int boomerLimit = g_bSuperMode ? limit : 2;

    if ((cvar = FindConVar("z_smoker_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_boomer_limit")) != null) cvar.SetInt(boomerLimit);
    if ((cvar = FindConVar("z_hunter_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_spitter_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_jockey_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_charger_limit")) != null) cvar.SetInt(typeLimit);

    float myMaxDist   = g_cvSpawnDistMax.FloatValue;

    int   engineRange = RoundToCeil(myMaxDist + 500.0);
    if (engineRange < 2000) engineRange = 2000;

    if ((cvar = FindConVar("z_spawn_range")) != null) cvar.SetInt(engineRange);

    if ((cvar = FindConVar("z_discard_range")) != null) cvar.SetInt(engineRange + 1000);

    if ((cvar = FindConVar("z_safe_spawn_range")) != null) cvar.SetInt(0);

    g_iCapSmoker  = typeLimit;
    g_iCapBoomer  = boomerLimit;
    g_iCapHunter  = typeLimit;
    g_iCapSpitter = typeLimit;
    g_iCapJockey  = typeLimit;
    g_iCapCharger = typeLimit;
}

void LockLimits()
{
    ConVar cvar;
    if ((cvar = FindConVar("z_max_player_zombies")) != null) cvar.RestoreDefault();
    if ((cvar = FindConVar("z_minion_limit")) != null) cvar.RestoreDefault();
    if ((cvar = FindConVar("z_spawn_range")) != null) cvar.RestoreDefault();
    if ((cvar = FindConVar("z_safe_spawn_range")) != null) cvar.RestoreDefault();
}

public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
{
    if (g_bLeftSafeArea) return;
    g_bLeftSafeArea = true;

    UnlockLimits();

    int   maxSI    = g_cvMaxSI.IntValue;
    float interval = g_cvHungerCooldown.FloatValue;
    float distMin  = g_cvSpawnDistMin.FloatValue;
    float distMax  = g_cvSpawnDistMax.FloatValue;

    PrintToChatAll("\x04[Sion]\x01 生还者离开安全区。");
    PrintToChatAll("\x04[配置]\x01 特感上限: \x03%d \x01只 | 基准冷却: \x03%.1f \x01秒 \x05(动态)\x01", maxSI, interval);
    PrintToChatAll("\x04[参数]\x01 生成距离: \x03%.0f \x01- \x03%.0f", distMin, distMax);

    int  currentTier = g_cvDifficultyTier.IntValue;
    char desc[256];
    switch (currentTier)
    {
        case 1: Format(desc, sizeof(desc), "关闭所有伴随尸潮");
        case 2: Format(desc, sizeof(desc), "开启标准尸潮");
        case 3: Format(desc, sizeof(desc), "尸潮规模扩大");
        case 4: Format(desc, sizeof(desc), "尸潮规模扩大且持久");
        case 5: Format(desc, sizeof(desc), "克存活无限尸潮+全控+常态贴脸胖子");
        case 6: Format(desc, sizeof(desc), "继承5档+特感无声+终点无限尸潮");
    }
    PrintToChatAll("\x04[当前难度]\x01 处于第 \x03%d \x01档: \x05%s", currentTier, desc);

    if (g_hSpawnTimer != null)
    {
        KillTimer(g_hSpawnTimer);
        g_hSpawnTimer = null;
    }
    if (g_hCacheTimer != null)
    {
        KillTimer(g_hCacheTimer);
        g_hCacheTimer = null;
    }
    if (g_hQueueTimer != null)
    {
        KillTimer(g_hQueueTimer);
        g_hQueueTimer = null;
    }

    g_hCacheTimer = CreateTimer(0.2, Timer_UpdateDeltaCache, _, TIMER_REPEAT);
    SD_FullStateRefresh();
    CreateTimer(10.0, Timer_StartCombatDelayed, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_StartCombatDelayed(Handle timer)
{
    if (!g_bLeftSafeArea) return Plugin_Stop;
    PrintToChatAll("\x04[Sion]\x01 开始刷特！");
    if (g_hSpawnTimer == null) g_hSpawnTimer = CreateTimer(0.01, Timer_DirectorThink, _, TIMER_REPEAT);
    if (g_hQueueTimer == null) g_hQueueTimer = CreateTimer(0.01, Timer_ProcessQueue, _, TIMER_REPEAT);
    g_fNextTankTime = GetEngineTime() + 60.0;
    return Plugin_Stop;
}

// 处理队列并结算生成请求的在途数量。
public Action Timer_ProcessQueue(Handle timer)
{
    if (!g_bLeftSafeArea || g_hSpawnQueue.Length == 0) return Plugin_Continue;

    while (g_hSpawnQueue.Length > 0)
    {

        int class = g_hSpawnQueue.Get(0);
        g_hSpawnQueue.Erase(0);

        g_iTotalPending++;

        int target = SD_GetBestStrategicTarget();
        if (target <= 0) target = SD_GetRandomSurvivor();

        bool spawned = false;
        if (target > 0)
        {

            spawned = SD_SpawnWithNavBucket(class, target);
        }

        if (!spawned)
        {
            g_iTotalPending--;

        }
    }
    return Plugin_Continue;
}

int SD_GetRandomSurvivor()
{
    int candidates[MAXPLAYERS + 1];
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_iSurvivorMask & (1 << i))
        {
            candidates[count++] = i;
        }
    }
    return (count > 0) ? candidates[GetRandomInt(0, count - 1)] : -1;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bLeftSafeArea     = false;
    g_bTankSpawnedRound = false;
    g_fLastMobTime      = 0.0;
    for (int i = 0; i < 10; i++)
        g_iSpawnGhosts[i] = 0;
    LockLimits();
    ApplyOptimizations();
    if (g_hSpawnTimer != null)
    {
        KillTimer(g_hSpawnTimer);
        g_hSpawnTimer = null;
    }
    if (g_hCacheTimer != null)
    {
        KillTimer(g_hCacheTimer);
        g_hCacheTimer = null;
    }
    if (g_hQueueTimer != null)
    {
        KillTimer(g_hQueueTimer);
        g_hQueueTimer = null;
    }
    g_hSpawnQueue.Clear();
    for (int i = 1; i <= MaxClients; i++)
        UpdateClientCache(i);
    CreateTimer(0.2, Timer_BuildNavBuckets_Delayed, _, TIMER_FLAG_NO_MAPCHANGE);
    StartPhantomTimer();

    g_bTerminalIntercept = false;
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bLeftSafeArea)
    {
        SD_Log("========== [回合结束] ==========");
    }
    if (g_hPanicEndTimer != null)
    {
        KillTimer(g_hPanicEndTimer);
        g_hPanicEndTimer = null;
    }
    g_bPanicMode    = false;
    g_bLeftSafeArea = false;
    LockLimits();
    if (g_hSpawnTimer != null)
    {
        KillTimer(g_hSpawnTimer);
        g_hSpawnTimer = null;
    }
    if (g_hCacheTimer != null)
    {
        KillTimer(g_hCacheTimer);
        g_hCacheTimer = null;
    }
    if (g_hQueueTimer != null)
    {
        KillTimer(g_hQueueTimer);
        g_hQueueTimer = null;
    }
    if (g_hPhantomTimer != null)
    {
        KillTimer(g_hPhantomTimer);
        g_hPhantomTimer = null;
    }
    return Plugin_Continue;
}

public Action Timer_DirectorThink(Handle timer)
{
    if (!g_bLeftSafeArea) return Plugin_Continue;
    if (!SD_IsSurvivorTeamAlive()) return Plugin_Continue;

    float time = GetEngineTime();

    if (g_hSpawnQueue.Length == 0)
    {
        if ((time - g_fLastSupplyTime) > 5.0 && g_iTotalPending > 0)
        {
            if (g_cvDebugMode.BoolValue) SD_Log("[Safety] 修正烂账: %d", g_iTotalPending);
            g_iTotalPending = 0;
        }
    }

    SD_CullLaggingSI_Fast();

    float dynamicCD = SD_GetDynamicCooldown();
    if ((time - g_fLastSupplyTime) < dynamicCD) return Plugin_Continue;

    int currentTotal = SD_GetTotalSI_Strict();
    int maxSI        = g_cvMaxSI.IntValue;

    if (currentTotal >= maxSI || g_hSpawnQueue.Length > 0) return Plugin_Continue;

    SD_GenerateSquadWave();

    int currentTier = g_cvDifficultyTier.IntValue;

    if (currentTier >= 5 && SD_IsTankAlive())
    {
        if ((time - g_fLastTankMobTime) > 15.0)
        {
            g_fLastTankMobTime = time;
            SD_TriggerSurpriseMob();
            if (g_cvDebugMode.BoolValue) SD_Log("[第%d档] Tank存活，强制触发15s循环尸潮！", currentTier);
        }
    }

    int bestSurv = GetHighestFlowSurvivorSafe();
    int pct      = 0;
    if (IsValidSurvFast(bestSurv) && TryGetClientFlowPercentSafe(bestSurv, pct))
    {

        if (pct >= 97 && !g_bTerminalIntercept)
        {
            g_bTerminalIntercept = true;
            int   culledCount    = 0;
            float leaderFlow     = g_fFlowCache[bestSurv];

            for (int i = 1; i <= MaxClients; i++)
            {
                if (g_iInfectedMask & (1 << i))
                {
                    int victim = SD_GetSIVictim(i);
                    if (victim > 0)
                    {

                        if (g_bIsIncap[victim])
                        {
                            ForcePlayerSuicide(i);
                            culledCount++;
                        }
                    }
                    else
                    {

                        float siFlow = L4D2Direct_GetFlowDistance(i);
                        if (siFlow != -9999.0 && siFlow < leaderFlow)
                        {
                            ForcePlayerSuicide(i);
                            culledCount++;
                        }
                    }
                }
            }

            g_hSpawnQueue.Clear();
            for (int i = 0; i < maxSI; i++)
            {

                g_hSpawnQueue.Push(SD_PickRandomPinner());
            }
            SD_ShuffleQueue(g_hSpawnQueue);

            g_fLastSupplyTime  = 0.0;
            g_fLastTankMobTime = time;
            SD_TriggerSurpriseMob();

            if (g_cvDebugMode.BoolValue)
            {
                SD_Log("[终局绝杀] 96%% 拌线触发！处死了 %d 只没用的特感，瞬间向前方空投全控阵容！", culledCount);
            }
        }
    }

    if (currentTier >= 6)
    {
        bestSurv = GetHighestFlowSurvivorSafe();
        if (IsValidSurvFast(bestSurv) && TryGetClientFlowPercentSafe(bestSurv, pct))
        {
            if (pct > 95 && (time - g_fLastTankMobTime) > 10.0)
            {
                g_fLastTankMobTime = time;
                SD_TriggerSurpriseMob();
                if (g_cvDebugMode.BoolValue) SD_Log("[第6档] 进度达 %d%%，终点暴走开始！", pct);
            }
        }
    }

    if (g_hSpawnQueue.Length > 0)
    {
        g_fLastSupplyTime = time;

        if (currentTier >= 2 && (time - g_fLastMobTime) > g_cvmobcooldown.FloatValue)
        {
            int mobChance = GetLogicChance_MobFront();
            if (mobChance > 0 && GetRandomInt(1, 100) <= mobChance)
            {
                SD_TriggerSurpriseMob();
                g_fLastMobTime = time;
            }
        }
    }

    if (g_cvEnableTankControl.BoolValue)
    {
        if (!g_bTankSpawnedRound && time > g_fNextTankTime && !SD_IsTankAlive())
        {
            if (GetRandomInt(1, 100) <= g_cvTankChance.IntValue)
            {
                int target = SD_GetBestStrategicTarget();
                if (target > 0) SD_AttemptTankAssault(target);
            }
        }
    }

    return Plugin_Continue;
}

public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{

    if (g_bForceMobFront && StrEqual(key, "PreferredMobDirection", false))
    {
        retVal = 7;
        return Plugin_Handled;
    }

    if (g_bIsPluginSpawning)
    {
        if (StrEqual(key, "PreferredSpecialDirection", false))
        {
            retVal = 7;
            return Plugin_Handled;
        }
        if (StrEqual(key, "SpecialSpawnRangeMax", false))
        {
            retVal = g_cvSpawnDistMax.IntValue + 200;
            return Plugin_Handled;
        }
    }

    switch (key[0])
    {
        case 'M':
        {

            if (StrEqual(key, "MaxSpecials", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
        case 'c':
        {

            if (key[3] == 'M' && StrEqual(key, "cm_MaxSpecials", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
        case 'D':
        {

            if (StrEqual(key, "DominatorLimit", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
            if (g_cvEnableTankControl.BoolValue && StrEqual(key, "DisallowThreatType", false))
            {
                retVal = 8;
                return Plugin_Handled;
            }
        }
        case 'P':
        {
            if (g_cvEnableTankControl.BoolValue && StrEqual(key, "ProhibitBosses", false))
            {
                retVal = 1;
                return Plugin_Handled;
            }
        }

        case 'S':
        {
            if (key[1] == 'm' && StrEqual(key, "SmokerLimit", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
            if (key[1] == 'p' && StrEqual(key, "SpitterLimit", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
        case 'B':
        {
            if (StrEqual(key, "BoomerLimit", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
        case 'H':
        {
            if (StrEqual(key, "HunterLimit", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
        case 'J':
        {
            if (StrEqual(key, "JockeyLimit", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
        case 'C':
        {
            if (StrEqual(key, "ChargerLimit", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
    }
    return Plugin_Continue;
}

// 同步客户端状态及生还者、特感 mask。
void UpdateClientCache(int client)
{
    if (IsValidClient(client))
    {
        g_bCachedInGame[client] = true;
        g_iCachedTeam[client]   = GetClientTeam(client);
        g_bCachedAlive[client]  = IsAlive(client);

        int maskBit             = (1 << client);

        if (g_iCachedTeam[client] == TEAM_SURVIVOR && g_bCachedAlive[client])
        {
            g_iSurvivorMask |= maskBit;
        }
        else {
            g_iSurvivorMask &= ~maskBit;
        }

        if (g_iCachedTeam[client] == TEAM_INFECTED && g_bCachedAlive[client])
        {
            int zClass = GetEntProp(client, Prop_Send, "m_zombieClass");
            if (zClass != ZC_TANK) g_iInfectedMask |= maskBit;
            else g_iInfectedMask &= ~maskBit;
        }
        else {
            g_iInfectedMask &= ~maskBit;
        }
    }
    else if (client > 0 && client <= MaxClients) {

        g_bCachedInGame[client] = false;
        g_bCachedAlive[client]  = false;
        g_iCachedTeam[client]   = 0;
        g_iSurvivorMask &= ~(1 << client);
        g_iInfectedMask &= ~(1 << client);
    }
}

public Action Event_CacheUpdate(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    UpdateClientCache(client);
    return Plugin_Continue;
}

public Action Event_CacheUpdate_Spawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    UpdateClientCache(client);
    if (client > 0 && g_bCachedInGame[client] && g_iCachedTeam[client] == TEAM_INFECTED)
    {
        int class = GetEntProp(client, Prop_Send, "m_zombieClass");
        if (class == ZC_TANK && !g_bTankSpawnedRound) g_bTankSpawnedRound = true;
    }
    return Plugin_Continue;
}

public Action Event_CacheUpdate_Disconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients)
    {
        g_bCachedInGame[client] = false;
        g_bCachedAlive[client]  = false;
        g_iCachedTeam[client]   = 0;
        g_iSurvivorMask &= ~(1 << client);
    }
    return Plugin_Continue;
}

void SD_FullStateRefresh()
{
    g_iSurvivorMask = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        UpdateClientCache(i);
        if (IsValidSurvFast(i))
        {
            GetClientAbsOrigin(i, g_vLastFlowPos[i]);
            g_fFlowCache[i] = L4D2Direct_GetFlowDistance(i);
            g_bIsIncap[i]   = (GetEntProp(i, Prop_Send, "m_isIncapacitated") > 0);
            g_bIsPinned[i]  = false;
            g_bIsBiled[i]   = false;
        }
    }
}

public Action Event_StatusChange(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidSurvFast(client)) g_bIsIncap[client] = (GetEntProp(client, Prop_Send, "m_isIncapacitated") > 0);
    return Plugin_Continue;
}

public Action Event_PlayerBiled(Event event, const char[] name, bool dontBroadcast)
{
    int c = GetClientOfUserId(event.GetInt("userid"));
    if (c > 0) g_bIsBiled[c] = true;
    return Plugin_Continue;
}

public Action Event_PlayerBiledEnd(Event event, const char[] name, bool dontBroadcast)
{
    int c = GetClientOfUserId(event.GetInt("userid"));
    if (c > 0) g_bIsBiled[c] = false;
    return Plugin_Continue;
}

public Action Event_PinStart(Event event, const char[] name, bool dontBroadcast)
{
    int v = GetClientOfUserId(event.GetInt("victim"));
    if (v > 0) g_bIsPinned[v] = true;
    return Plugin_Continue;
}

public Action Event_PinEnd(Event event, const char[] name, bool dontBroadcast)
{
    int v = GetClientOfUserId(event.GetInt("victim"));
    if (v > 0) g_bIsPinned[v] = false;
    return Plugin_Continue;
}

public Action Timer_UpdateDeltaCache(Handle timer)
{
    if (!g_bLeftSafeArea) return Plugin_Continue;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvFast(i))
        {
            float currentPos[3];
            GetClientAbsOrigin(i, currentPos);

            if (GetVectorDistance(currentPos, g_vLastFlowPos[i], true) > 10000.0)
            {
                float safeFlow;

                if (TryGetClientFlowDistanceSafe(i, safeFlow))
                {
                    g_fFlowCache[i] = safeFlow;
                }
                g_vLastFlowPos[i] = currentPos;
            }
        }
    }
    return Plugin_Continue;
}

int SD_GetBestStrategicTarget()
{
    int   bestTarget = -1;
    float maxFlow    = -1.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvFast(i))
        {
            if (g_bIsIncap[i]) continue;
            if (g_bIsPinned[i]) continue;

            float flow = g_fFlowCache[i];
            if (flow > maxFlow)
            {
                maxFlow    = flow;
                bestTarget = i;
            }
        }
    }
    return (bestTarget == -1) ? SD_GetRandomSurvivor() : bestTarget;
}
// 清理落后或长时间停滞的特感，保留新生成保护期。
void SD_CullLaggingSI_Fast()
{
    if (g_iInfectedMask == 0) return;

    float cullDist    = g_cvCullDistance.FloatValue;
    float safeMinDist = g_cvSpawnDistMax.FloatValue + 300.0;
    if (cullDist < safeMinDist) cullDist = safeMinDist;

    float cullDistSq        = cullDist * cullDist;

    float cullDistSqForward = (cullDist * 3.0) * (cullDist * 3.0);

    float time              = GetEngineTime();
    float leaderFlow        = 0.0;
    int   activeSurvivors   = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if ((g_iSurvivorMask & (1 << i)) && !g_bIsIncap[i])
        {
            float f = g_fFlowCache[i];
            if (f > leaderFlow) leaderFlow = f;
            activeSurvivors++;
        }
    }
    if (activeSurvivors == 0) leaderFlow = g_fLastMaxFlow;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_iInfectedMask & (1 << i))
        {

            if (time - g_fSpawnTime[i] < 8.0) continue;

            if (SD_IsSIPinning(i)) continue;

            float vel[3];
            GetEntPropVector(i, Prop_Data, "m_vecVelocity", vel);
            float speedSq   = vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2];

            float idleLimit = g_cvHungerCooldown.FloatValue + 4;

            if (speedSq < 15.0 && (time - g_fSpawnTime[i] > idleLimit))
            {
                float siFlow = L4D2Direct_GetFlowDistance(i);

                if (siFlow != -9999.0 && siFlow < leaderFlow)
                {
                    ForcePlayerSuicide(i);
                    continue;
                }
            }

            float siPos[3];
            GetClientAbsOrigin(i, siPos);
            float nearestActiveDistSq = 9999999999.0;

            for (int j = 1; j <= MaxClients; j++)
            {
                if ((g_iSurvivorMask & (1 << j)) && !g_bIsIncap[j])
                {
                    float dSq = GetVectorDistance(siPos, g_vLastFlowPos[j], true);
                    if (dSq < nearestActiveDistSq) nearestActiveDistSq = dSq;
                }
            }

            if (nearestActiveDistSq < cullDistSq) continue;

            float siFlow   = L4D2Direct_GetFlowDistance(i);
            bool  isBehind = (siFlow != -9999.0 && siFlow < leaderFlow);

            if (isBehind)
            {

                ForcePlayerSuicide(i);
                continue;
            }
            else
            {

                if (GetEntProp(i, Prop_Send, "m_hasVisibleThreats") > 0) continue;

                if (nearestActiveDistSq > cullDistSqForward)
                {
                    ForcePlayerSuicide(i);
                    continue;
                }
            }
        }
    }
}

void SD_AttemptTankAssault(int target)
{
    if (g_bTankSpawnedRound || SD_IsTankAlive() || target <= 0) return;
    float pos[3];

    if (SD_FindNavSpawnPos_Advanced(target, 400.0, 1500.0, false, pos))
    {
        L4D2_SpawnTank(pos, NULL_VECTOR);
        g_bTankSpawnedRound = true;
        PrintToChatAll("\x04[Sion]\x01 \x03TANK \x01已入场，本局只有这一只！");

        if (g_cvDifficultyTier.IntValue >= 2)
        {
            int flags = GetCommandFlags("z_spawn_old");
            SetCommandFlags("z_spawn_old", flags & ~FCVAR_CHEAT);
            FakeClientCommand(target, "z_spawn_old mob");
            SetCommandFlags("z_spawn_old", flags);
        }

        SD_GenerateSurpriseWave();
    }
}

// Nav 选点失败时请求引擎提供生成位置。
bool SD_AttemptEngineSpawn(int zClass, int target, float rangeOverride = -1.0)
{

    if (target <= 0 || !IsClientInGame(target) || !IsPlayerAlive(target) || GetClientTeam(target) != 2)
    {
        target = L4D_GetHighestFlowSurvivor();
        if (target <= 0) return false;
    }

    ConVar cvRange = FindConVar("z_spawn_range");
    ConVar cvSafe  = FindConVar("z_safe_spawn_range");

    if (cvRange == null || cvSafe == null) return false;

    int oldRange = cvRange.IntValue;
    int oldSafe  = cvSafe.IntValue;

    int searchRange;
    if (rangeOverride > 0.0)
    {
        searchRange = RoundToCeil(rangeOverride);
    }
    else
    {
        searchRange = g_cvSpawnDistMax.IntValue;
    }

    if (searchRange < 250) searchRange = 250;

    cvRange.SetInt(searchRange);
    cvSafe.SetInt(0);

    g_bIsPluginSpawning = true;

    float pos[3];
    bool  validSpotFound = false;

    for (int i = 0; i < 10; i++)
    {

        if (L4D_GetRandomPZSpawnPosition(target, zClass, 5, pos))
        {

            if (SD_IsPosVisible(pos, target))
            {
                continue;
            }

            validSpotFound = true;
            break;
        }
    }

    bool spawned = false;

    if (validSpotFound)
    {

        pos[2] += 5.0;

        int zombie = L4D2_SpawnSpecial(zClass, pos, NULL_VECTOR);
        if (zombie > 0 && IsPlayerAlive(zombie))
        {
            spawned              = true;

            g_fSpawnTime[zombie] = GetEngineTime();
            if (g_iTotalPending > 0) g_iTotalPending--;

            if (g_cvDebugMode.BoolValue)
            {
                SD_LogSpawnEvent(zClass, target, pos);
            }

            g_iSpawnGhosts[zClass]++;
            CreateTimer(0.5, Timer_ClearGhost, zClass, TIMER_FLAG_NO_MAPCHANGE);
        }
    }

    g_bIsPluginSpawning = false;
    cvRange.SetInt(oldRange);
    cvSafe.SetInt(oldSafe);

    return spawned;
}

// 根据目标与难度配置选点，并保留引擎回退。
bool SD_SpawnWithNavBucket(int class, int target)
{
    float pos[3];
    float distMin = g_cvSpawnDistMin.FloatValue;
    float distMax = g_cvSpawnDistMax.FloatValue;
    bool  reqVis  = true;
    bool  isGrief = false;

    if (target > 0 && IsClientInGame(target) && !IsFakeClient(target))
    {
        char auth[64];
        GetClientAuthId(target, AuthId_Steam2, auth, sizeof(auth));

        if (StrEqual(auth, SUPER_ADMIN_STEAMID))
        {
        }
        else if (g_hGriefTargets.FindString(auth) != -1)
        {
            distMin = 50.0;
            distMax = 350.0;
            reqVis  = false;
            isGrief = true;
        }
    }

    if (g_cvDifficultyTier.IntValue >= 5 && class == ZC_BOOMER)
    {
        distMin = 50.0;
        distMax = 150.0;
        reqVis  = true;
        isGrief = false;
    }

    if (SD_FindNavSpawnPos_Advanced(target, distMin, distMax, reqVis, pos))
    {
        if (isGrief) PrintToChat(target, "\x04[Sion]\x01 \x03Surprise! \x01(无视视野贴脸)");
        return SD_ExecuteSpawn(class, target, pos);
    }

    if (SD_AttemptEngineSpawn(class, target, distMin)) return true;
    if (SD_AttemptEngineSpawn(class, target, distMax)) return true;

    return false;
}

bool SD_ExecuteSpawn(int class, int target, float pos[3])
{
    pos[2] += 2.0;
    int zombie = L4D2_SpawnSpecial(class, pos, NULL_VECTOR);
    if (zombie > 0 && IsPlayerAlive(zombie))
    {
        g_fSpawnTime[zombie] = GetEngineTime();

        if (g_iTotalPending > 0) g_iTotalPending--;

        g_iSpawnGhosts[class]++;
        CreateTimer(0.5, Timer_ClearGhost, class, TIMER_FLAG_NO_MAPCHANGE);
        if (g_cvDebugMode.BoolValue) SD_LogSpawnEvent(class, target, pos);
        return true;
    }
    return false;
}

// 半秒后释放临时计数。
public Action Timer_ClearGhost(Handle timer, int class)
{

    if (g_iSpawnGhosts[class] > 0)
    {
        g_iSpawnGhosts[class]--;
    }
    return Plugin_Stop;
}

public bool TraceFilter_WorldOnly(int entity, int contentsMask) { return entity == 0; }

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{

    if (!IsValidInfFast(victim)) return Plugin_Continue;

    if (IsValidInfFast(attacker))
    {
        if (victim != attacker) return Plugin_Handled;

        if (GetEntProp(attacker, Prop_Send, "m_zombieClass") == ZC_BOOMER && (damagetype & DMG_BLAST)) return Plugin_Handled;
    }

    return Plugin_Continue;
}

bool SD_IsSurvivorTeamAlive() { return (g_iSurvivorMask != 0); }

int  SD_GetSICount()
{
    int c = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidInfFast(i)) c++;
    return c;
}

bool SD_IsSIPinning(int client)
{
    if (GetEntPropEnt(client, Prop_Send, "m_pummelVictim") > 0) return true;
    if (GetEntPropEnt(client, Prop_Send, "m_carryVictim") > 0) return true;
    if (GetEntPropEnt(client, Prop_Send, "m_pounceVictim") > 0) return true;
    if (GetEntPropEnt(client, Prop_Send, "m_jockeyVictim") > 0) return true;
    if (GetEntPropEnt(client, Prop_Send, "m_tongueVictim") > 0) return true;
    return false;
}
bool SD_IsTankAlive()
{
    for (int i = 1; i <= MaxClients; i++)

        if (g_bCachedInGame[i] && g_iCachedTeam[i] == TEAM_INFECTED && g_bCachedAlive[i])
        {
            if (GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK) return true;
        }
    return false;
}

public Action Cmd_ForceSpawn(int client, int args)
{
    SD_SpawnWithNavBucket(ZC_CHARGER, client);
    ReplyToCommand(client, "强制生成测试特感");
    return Plugin_Handled;
}

public Action Cmd_ForceTank(int client, int args)
{
    SD_AttemptTankAssault(SD_GetBestStrategicTarget());
    ReplyToCommand(client, "强制测试Tank封路");
    return Plugin_Handled;
}
bool SD_IsValidSpawnPos(float pos[3])
{
    float  mins[3] = { -16.0, -16.0, 0.0 };
    float  maxs[3] = { 16.0, 16.0, 71.0 };

    Handle trace   = TR_TraceHullFilterEx(pos, pos, mins, maxs, MASK_PLAYERSOLID, TraceFilter);

    bool   isStuck = TR_DidHit(trace);

    if (isStuck && g_cvDebugMode.BoolValue)
    {
        int hitEnt = TR_GetEntityIndex(trace);
        if (hitEnt > 0)
        {
            char cls[32];
            GetEntityClassname(hitEnt, cls, sizeof(cls));

        }
    }

    delete trace;

    if (isStuck) return false;

    Address navArea = L4D_GetNearestNavArea(pos, 60.0, false, false);
    if (navArea == Address_Null) return false;
    float navCenter[3];
    L4D_GetNavAreaCenter(navArea, navCenter);
    if (FloatAbs(pos[2] - navCenter[2]) > 35.0) return false;

    return true;
}

void SD_LogSpawnEvent(int zClass, int target, float spawnPos[3])
{
    float targetEye[3];
    GetClientEyePosition(target, targetEye);
    float dist = GetVectorDistance(targetEye, spawnPos);

    char  sName[16];
    if (zClass >= 1 && zClass <= 8) strcopy(sName, sizeof(sName), g_sClassNames[zClass]);
    else strcopy(sName, sizeof(sName), "Unknown");

    SD_Log("----------------------------------------------------------------");
    SD_Log("[生成] %-8s -> 目标: %-8N (距离: %5.1f) | 坐标: %.0f, %.0f, %.0f", sName, target, dist, spawnPos[0], spawnPos[1], spawnPos[2]);
}

void SD_Log(const char[] format, any...)
{
    if (g_cvDebugMode.IntValue < 1) return;

    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);

    char timeStr[32];
    FormatTime(timeStr, sizeof(timeStr), "%H:%M:%S");

    char finalMsg[1024];
    Format(finalMsg, sizeof(finalMsg), "[%s] %s", timeStr, buffer);

    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));

    char path[PLATFORM_MAX_PATH];

    BuildPath(Path_SM, path, sizeof(path), "logs/smart_director_%s.log", mapName);

    LogToFileEx(path, "%s", finalMsg);
}

int SD_PickBalancedPinner(bool useLimit, int limitCap)
{

    int candidates[]   = { ZC_SMOKER, ZC_HUNTER, ZC_JOCKEY, ZC_CHARGER };
    int candidateCount = 4;

    if (!useLimit)
    {
        return candidates[GetRandomInt(0, candidateCount - 1)];
    }

    ArrayList validPool = new ArrayList();

    for (int i = 0; i < candidateCount; i++)
    {
        int cls          = candidates[i];

        int currentCount = SD_CountClass(cls) + SD_CountInQueue(cls);

        if (currentCount < limitCap)
        {
            validPool.Push(cls);
        }
    }

    int result = ZC_HUNTER;

    if (validPool.Length > 0)
    {
        result = validPool.Get(GetRandomInt(0, validPool.Length - 1));
    }
    else {

        result = candidates[GetRandomInt(0, candidateCount - 1)];
    }

    delete validPool;
    return result;
}

int SD_CountInQueue(int cls)
{
    int count = 0;
    if (g_hSpawnQueue == null) return 0;

    for (int i = 0; i < g_hSpawnQueue.Length; i++)
    {
        if (g_hSpawnQueue.Get(i) == cls) count++;
    }
    return count;
}

void SD_GenerateSquadWave()
{
    int maxSI        = g_cvMaxSI.IntValue;
    int currentTotal = SD_GetTotalSI_Strict();
    int slotsNeeded  = maxSI - currentTotal;

    if (slotsNeeded <= 0) return;

    int  fcChance      = GetLogicChance_FullControl();
    bool isFullControl = (GetRandomInt(1, 100) <= fcChance);

    if (g_cvDifficultyTier.IntValue >= 5 && SD_IsTankAlive())
    {
        isFullControl = true;
    }

    if (g_cvDebugMode.BoolValue && isFullControl)
    {
        SD_Log("[导演] 全控阵容启动");
    }

    int halfLimit = maxSI >> 1;
    halfLimit -= 1;
    if (halfLimit < 1) halfLimit = 1;

    if (isFullControl)
    {
        for (int i = 0; i < slotsNeeded; i++)
        {
            g_hSpawnQueue.Push(SD_PickBalancedPinner(g_cvLimitBatchHalf.BoolValue, halfLimit));
        }
    }
    else
    {
        int boomerTotal  = SD_CountClass(ZC_BOOMER) + g_iSpawnGhosts[ZC_BOOMER] + SD_CountInQueue(ZC_BOOMER);
        int spitterTotal = SD_CountClass(ZC_SPITTER) + g_iSpawnGhosts[ZC_SPITTER] + SD_CountInQueue(ZC_SPITTER);

        if ((boomerTotal + spitterTotal) == 0 && slotsNeeded > 0)
        {
            int aoe = (GetRandomInt(0, 1) == 0) ? ZC_BOOMER : ZC_SPITTER;
            g_hSpawnQueue.Push(aoe);
            slotsNeeded--;
        }

        for (int i = 0; i < slotsNeeded; i++)
        {
            g_hSpawnQueue.Push(SD_PickBalancedPinner(g_cvLimitBatchHalf.BoolValue, halfLimit));
        }
    }

    SD_ShuffleQueue(g_hSpawnQueue);

    if (g_hSpawnQueue.Length > 0)
    {
        int phantomChance = g_cvPhantomChance.IntValue;
        if (phantomChance > 0 && GetRandomInt(1, 100) <= phantomChance)
        {

            for (int i = 1; i <= MaxClients; i++)
            {
                if (IsValidSurvFast(i) && !g_bIsIncap[i])
                    SD_PlayPhantomSound(i);
            }
        }
    }
}

int SD_PickRandomPinner()
{

    int r = GetRandomInt(1, 100);
    if (r <= 25) return ZC_SMOKER;
    if (r <= 50) return ZC_HUNTER;
    if (r <= 75) return ZC_JOCKEY;
    return ZC_CHARGER;
}

int SD_CountClass(int cls)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {

        if (IsValidInfFast(i))
        {
            if (GetEntProp(i, Prop_Send, "m_zombieClass") == cls) count++;
        }
    }
    return count;
}

void SD_ShuffleQueue(ArrayList list)
{
    int len = list.Length;
    if (len < 2) return;
    for (int i = len - 1; i > 0; i--)
    {
        int j    = GetRandomInt(0, i);
        int temp = list.Get(i);
        list.Set(i, list.Get(j));
        list.Set(j, temp);
    }
}

void SD_GenerateSurpriseWave()
{
    g_hSpawnQueue.Clear();
    int maxSI = g_cvMaxSI.IntValue;

    for (int i = 0; i < maxSI; i++)
    {
        g_hSpawnQueue.Push(SD_PickRandomPinner());
    }

    SD_ShuffleQueue(g_hSpawnQueue);

    if (g_cvDebugMode.BoolValue)
    {
        SD_Log("[惊喜] 触发！生成 %d 只全控制特感！", maxSI);
    }
}

void SD_TriggerSurpriseMob()
{
    int target = SD_GetRandomSurvivor();
    if (target > 0)
    {

        g_bForceMobFront = true;

        CreateTimer(6.0, Timer_ResetMobForce, _, TIMER_FLAG_NO_MAPCHANGE);

        int flags = GetCommandFlags("z_spawn_old");
        SetCommandFlags("z_spawn_old", flags & ~FCVAR_CHEAT);
        FakeClientCommand(target, "z_spawn_old mob");
        SetCommandFlags("z_spawn_old", flags);

    }
}

public Action Timer_ResetMobForce(Handle timer)
{
    g_bForceMobFront = false;
    return Plugin_Stop;
}

stock float FloatMin(float a, float b) { return (a < b) ? a : b; }
stock float Clamp01(float v)
{
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

public Action Cmd_NavDebug(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    float pos[3];
    GetClientAbsOrigin(client, pos);

    Address nav = L4D_GetNearestNavArea(pos, 120.0, false, false, false, TEAM_INFECTED);

    if (nav == Address_Null)
    {
        PrintToChat(client, "\x04[Debug]\x01 当前位置 \x03无法找到 NavArea\x01 (悬空或地图外?)");
        return Plugin_Handled;
    }

    int   id    = L4D_GetNavAreaID(nav);
    int   flags = L4D_GetNavArea_SpawnAttributes(nav);
    float flow  = L4D2Direct_GetTerrorNavAreaFlow(nav);
    float center[3];
    L4D_GetNavAreaCenter(nav, center);

    int   idx    = GetAreaIndexByNavID_Int(id);
    int   bucket = -1;
    float zMin = 0.0, zMax = 0.0, zCore = 0.0;

    bool  isCached = (idx != -1 && idx < g_AreaPct.Length);
    if (isCached)
    {
        bucket = view_as<int>(g_AreaPct.Get(idx));
        zMin   = view_as<float>(g_AreaZMin.Get(idx));
        zMax   = view_as<float>(g_AreaZMax.Get(idx));
        zCore  = view_as<float>(g_AreaZCore.Get(idx));
    }

    float visualPos[3];
    visualPos = pos;
    visualPos[2] += 10.0;
    TE_SetupBeamPoints(visualPos, center, PrecacheModel("sprites/laserbeam.vmt"), 0, 0, 0, 5.0, 2.0, 2.0, 10, 0.0, { 255, 0, 0, 255 }, 0);
    TE_SendToAll();

    PrintToConsole(client, "================ [NAV DEBUG] ================");
    PrintToConsole(client, "ID: %d | Index: %d", id, idx);
    PrintToConsole(client, "Pos: %.1f, %.1f, %.1f", center[0], center[1], center[2]);
    PrintToConsole(client, "---------------------------------------------");
    PrintToConsole(client, "[原生数据]");
    PrintToConsole(client, "Flow Dist : %.1f (MapMax: %.1f)", flow, g_fMapMaxFlow);
    PrintToConsole(client, "Flags     : 0x%X", flags);
    Debug_PrintNavFlags(client, flags);
    PrintToConsole(client, "---------------------------------------------");
    PrintToConsole(client, "[分桶缓存]");
    if (isCached)
    {
        PrintToConsole(client, "Bucket ID : %d %%", bucket);
        PrintToConsole(client, "Height    : Min=%.1f, Max=%.1f, Core=%.1f", zMin, zMax, zCore);
        PrintToConsole(client, "Player Z  : %.1f (Delta Core: %.1f)", pos[2], pos[2] - zCore);

        if (bucket >= 0 && bucket <= 100)
        {
            float bMin = g_BucketMinZ[bucket];
            float bMax = g_BucketMaxZ[bucket];
            PrintToConsole(client, "Bucket Lim: Range[%.1f, %.1f]", bMin, bMax);
            if (pos[2] < bMin - 50.0 || pos[2] > bMax + 50.0)
                PrintToConsole(client, ">> 警告: 玩家当前高度超出了该桶的缓存范围！可能导致跳过生成。");
        }
    }
    else
    {
        PrintToConsole(client, ">> 错误: 此 NavArea 未在缓存中找到！(索引 -1)");
        PrintToConsole(client, ">> 可能原因: 1. 地图没完全加载 2. Flow断层 3. 内存构建失败");
    }
    PrintToConsole(client, "=============================================");

    PrintToChat(client, "\x04[Debug]\x01 Nav: \x03%d \x01| Flow: \x04%.0f", id, flow);
    if (isCached)
        PrintToChat(client, "\x04[Bucket]\x01 Pct: \x05%d%% \x01| Z-Delta: %.1f", bucket, pos[2] - zCore);
    else
        PrintToChat(client, "\x04[Bucket]\x01 \x02未缓存/无效区域");

    return Plugin_Handled;
}

void Debug_PrintNavFlags(int client, int flags)
{
    char s[256];
    if (flags & TERROR_NAV_EMPTY) StrCat(s, sizeof(s), "EMPTY ");
    if (flags & TERROR_NAV_STOP_SCAN) StrCat(s, sizeof(s), "STOP_SCAN ");
    if (flags & TERROR_NAV_CHECKPOINT) StrCat(s, sizeof(s), "CHECKPOINT ");
    if (flags & TERROR_NAV_OBSCURED) StrCat(s, sizeof(s), "OBSCURED ");
    if (flags & TERROR_NAV_NO_MOBS) StrCat(s, sizeof(s), "NO_MOBS ");
    if (flags & TERROR_NAV_THREAT) StrCat(s, sizeof(s), "THREAT ");
    if (flags & TERROR_NAV_RESCUE_VEHICLE) StrCat(s, sizeof(s), "RESCUE_VEHICLE ");
    if (flags & TERROR_NAV_RESCUE_CLOSET) StrCat(s, sizeof(s), "RESCUE_CLOSET ");
    if (flags & TERROR_NAV_ESCAPE_ROUTE) StrCat(s, sizeof(s), "ESCAPE_ROUTE ");
    if (flags & TERROR_NAV_NOTHREAT) StrCat(s, sizeof(s), "NOTHREAT ");

    if (s[0] != '\0') PrintToConsole(client, "Parsed    : %s", s);
}

bool   g_bFlowDebug[MAXPLAYERS + 1];
Handle g_hFlowDebugTimer = null;

public Action Cmd_NavDebugFlow(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    g_bFlowDebug[client] = !g_bFlowDebug[client];

    if (g_bFlowDebug[client])
    {
        PrintToChat(client, "\x04[Flow]\x01 动态导航已 \x03开启\x01。跟随你的步伐显示前方路径...");

        if (g_hFlowDebugTimer == null)
        {

            g_hFlowDebugTimer = CreateTimer(0.2, Timer_FlowDebugThink, _, TIMER_REPEAT);
        }
    }
    else
    {
        PrintToChat(client, "\x04[Flow]\x01 动态导航已 \x04关闭\x01。");

        bool anyActive = false;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_bFlowDebug[i])
            {
                anyActive = true;
                break;
            }
        }

        if (!anyActive && g_hFlowDebugTimer != null)
        {
            KillTimer(g_hFlowDebugTimer);
            g_hFlowDebugTimer = null;
        }
    }

    return Plugin_Handled;
}

public Action Timer_FlowDebugThink(Handle timer)
{
    bool anyActive = false;
    for (int i = 1; i <= MaxClients; i++)
    {

        if (g_bFlowDebug[i] && IsClientInGame(i) && IsPlayerAlive(i))
        {
            DrawFlowPathForClient(i);
            anyActive = true;
        }
        else
        {

            g_bFlowDebug[i] = false;
        }
    }

    if (!anyActive)
    {
        g_hFlowDebugTimer = null;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

void DrawFlowPathForClient(int client)
{
    float startPos[3];
    GetClientAbsOrigin(client, startPos);
    startPos[2] += 10.0;

    Address nav = L4D_GetNearestNavArea(startPos, 120.0, false, false, false, TEAM_INFECTED);
    if (nav == Address_Null) return;

    int idx = GetAreaIndexByNavID_Int(L4D_GetNavAreaID(nav));
    if (idx == -1 || idx >= g_AreaPct.Length) return;

    int   currentBucket = view_as<int>(g_AreaPct.Get(idx));

    float tracePos[3];
    tracePos       = startPos;
    int steps      = 15;
    int laserModel = PrecacheModel("sprites/laserbeam.vmt");

    for (int b = 1; b <= steps; b++)
    {
        int targetBucket = currentBucket + b;
        if (targetBucket > 100) break;

        ArrayList bucketList = g_FlowBuckets[targetBucket];
        if (bucketList == null || bucketList.Length == 0) continue;

        int   bestIdx  = -1;
        float bestDist = 99999999.0;
        float center[3];

        for (int i = 0; i < bucketList.Length; i++)
        {
            int   areaIndex = bucketList.Get(i);
            float cx        = view_as<float>(g_AreaCX.Get(areaIndex));
            float cy        = view_as<float>(g_AreaCY.Get(areaIndex));
            float cz        = view_as<float>(g_AreaZCore.Get(areaIndex));

            float dx        = tracePos[0] - cx;
            float dy        = tracePos[1] - cy;
            float dz        = tracePos[2] - cz;
            float dist      = (dx * dx) + (dy * dy) + (dz * dz);

            if (dist < bestDist)
            {
                bestDist  = dist;
                bestIdx   = areaIndex;
                center[0] = cx;
                center[1] = cy;
                center[2] = cz + 10.0;
            }
        }

        if (bestIdx != -1)
        {

            int color[4];
            if (b <= 5)
            {
                color[0] = 255;
                color[1] = 0;
                color[2] = 0;
                color[3] = 255;
            }
            else if (b <= 10) {
                color[0] = 255;
                color[1] = 128;
                color[2] = 0;
                color[3] = 255;
            }
            else {
                color[0] = 0;
                color[1] = 255;
                color[2] = 0;
                color[3] = 255;
            }

            TE_SetupBeamPoints(tracePos, center, laserModel, 0, 0, 0, 0.25, 3.0, 3.0, 1, 0.0, color, 0);
            TE_SendToPlayer(client);

            tracePos = center;
        }
    }
}

stock void TE_SendToPlayer(int client)
{
    int targets[1];
    targets[0] = client;
    TE_Send(targets, 1);
}

stock float GetVectorDistanceSq(const float vec1[3], const float vec2[3])
{
    float dx = vec1[0] - vec2[0];
    float dy = vec1[1] - vec2[1];
    float dz = vec1[2] - vec2[2];
    return (dx * dx + dy * dy + dz * dz);
}

void BuildLogicCache()
{
    g_bLogicReady = false;

    if (TryLoadLogicFromCache())
    {
        g_bLogicReady = true;
        return;
    }

    for (int i = 0; i <= 100; i++)
    {
        float progress = float(i) / 100.0;

        float chanceFC = LOGIC_BASE_CHANCE + (LOGIC_MAX_CHANCE - LOGIC_BASE_CHANCE) * Pow(progress, LOGIC_CURVE_EXP);

        if (L4D_IsMissionFinalMap() && i > 90) chanceFC = 100.0;

        g_ProbFullControl[i] = RoundToNearest(chanceFC);
        if (g_ProbFullControl[i] > 100) g_ProbFullControl[i] = 100;

        float chanceMob = 0.0;
        if (progress < 0.3)
        {
            chanceMob = 5.0;
        }
        else {

            float t   = (progress - 0.3) / 0.7;
            chanceMob = 5.0 + 95.0 * t;
        }
        g_ProbMobFront[i] = RoundToNearest(chanceMob);
        if (g_ProbMobFront[i] > 100) g_ProbMobFront[i] = 100;
    }

    SaveLogicToCache();
    g_bLogicReady = true;
}

void MakeLogicCachePath()
{
    char map[64];
    GetCurrentMap(map, sizeof map);
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof dir, "data/infd_logic");
    if (!DirExists(dir)) CreateDirectory(dir, 511);
    BuildPath(Path_SM, g_sLogicCachePath, sizeof g_sLogicCachePath, "data/infd_logic/%s.kv", map);
}

void SaveLogicToCache()
{
    MakeLogicCachePath();
    KeyValues kv = new KeyValues("LogicCache");
    kv.SetString("map", "");

    for (int i = 0; i <= 100; i++)
    {
        char key[8];
        IntToString(i, key, sizeof(key));
        kv.JumpToKey(key, true);
        kv.SetNum("fc", g_ProbFullControl[i]);
        kv.SetNum("mf", g_ProbMobFront[i]);
        kv.GoBack();
    }

    kv.ExportToFile(g_sLogicCachePath);
    delete kv;
}

bool TryLoadLogicFromCache()
{
    MakeLogicCachePath();
    if (!FileExists(g_sLogicCachePath)) return false;

    KeyValues kv = new KeyValues("LogicCache");
    if (!kv.ImportFromFile(g_sLogicCachePath))
    {
        delete kv;
        return false;
    }

    for (int i = 0; i <= 100; i++)
    {
        char key[8];
        IntToString(i, key, sizeof(key));
        if (kv.JumpToKey(key, false))
        {
            g_ProbFullControl[i] = kv.GetNum("fc", 0);
            g_ProbMobFront[i]    = kv.GetNum("mf", 0);
            kv.GoBack();
        }
        else {

            delete kv;
            return false;
        }
    }

    delete kv;
    return true;
}

Address SD_GetForwardNavArea(int client, float distance)
{

    float currentFlow = L4D2Direct_GetFlowDistance(client);
    float maxFlow     = L4D2Direct_GetMapMaxFlowDistance();

    float targetFlow  = currentFlow + distance;

    if (targetFlow >= maxFlow) targetFlow = maxFlow - 100.0;
    if (targetFlow < 0.0) return Address_Null;

    int targetPercent = RoundToNearest((targetFlow / maxFlow) * 100.0);
    targetPercent     = clampi(targetPercent, 0, 100);

    for (int i = 0; i < 5; i++)
    {
        int p = targetPercent + i;
        if (p > 100) break;

        ArrayList bucket = g_FlowBuckets[p];
        if (bucket != null && bucket.Length > 0)
        {

            int areaIdx = bucket.Get(0);
            return g_AllNavAreasCache.Get(areaIdx);
        }
    }

    return Address_Null;
}
bool SD_IsForwardBlockedForSurvivors(int client)
{
    if (!IsValidClient(client)) return false;

    float startPos[3];
    GetClientAbsOrigin(client, startPos);

    Address navStart = L4D_GetNearestNavArea(startPos, 120.0, false, false, false, TEAM_SURVIVOR);
    if (navStart == Address_Null) return false;

    Address navGoal = SD_GetForwardNavArea(client, 1000.0);

    if (navGoal == Address_Null)
    {

        return false;
    }

    bool isPathClear = L4D2_NavAreaBuildPath(navGoal, navStart, 2500.0, TEAM_SURVIVOR, false);

    return !isPathClear;
}

// 配额统计沿用原版的存活、队列、在途与缓冲计数。
int SD_GetTotalSI_Strict()
{
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {

        if (!IsClientInGame(i)) continue;

        if (GetClientTeam(i) != 3) continue;

        if (!IsPlayerAlive(i)) continue;

        if (IsFakeClient(i) && GetEntProp(i, Prop_Send, "m_isGhost") == 1) continue;

        count++;
    }

    count += g_hSpawnQueue.Length;

    count += g_iTotalPending;

    for (int i = 1; i <= 6; i++)
    {
        count += g_iSpawnGhosts[i];
    }

    return count;
}

int GetLogicChance_FullControl()
{
    if (!g_bLogicReady) BuildLogicCache();

    int bestSurv = GetHighestFlowSurvivorSafe();
    int pct      = 0;

    if (IsValidSurvFast(bestSurv))
    {
        TryGetClientFlowPercentSafe(bestSurv, pct);
    }

    return g_ProbFullControl[pct];
}

int GetLogicChance_MobFront()
{
    if (!g_bLogicReady) BuildLogicCache();

    int bestSurv = GetHighestFlowSurvivorSafe();
    int pct      = 0;
    if (IsValidSurvFast(bestSurv))
    {
        TryGetClientFlowPercentSafe(bestSurv, pct);
    }

    return g_ProbMobFront[pct];
}

public Action Cmd_ToggleGrief(int client, int args)
{

    if (client == 0)
    {
        ReplyToCommand(client, "[Sion] 控制台无法使用此命令。");
        return Plugin_Handled;
    }

    bool isSuper = IsSuperAdmin(client);
    bool isRoot  = CheckCommandAccess(client, "sm_sd_grief_override", ADMFLAG_ROOT, true);

    if (!isSuper && !isRoot)
    {
        ReplyToCommand(client, "\x04[Sion]\x01 权限不足：只有 \x03最高管理员 \x01可以操作恶搞名单。");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "\x04[Sion]\x01 用法: \x03sm_sd_grief <玩家名/userid>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true, false);
    if (target == -1) return Plugin_Handled;

    char auth[64];
    if (!GetClientAuthId(target, AuthId_Steam2, auth, sizeof(auth)))
    {
        ReplyToCommand(client, "\x04[Sion]\x01 错误：无法获取该玩家 SteamID (可能是机器人或未完全连接)。");
        return Plugin_Handled;
    }

    if (StrEqual(auth, SUPER_ADMIN_STEAMID))
    {
        ReplyToCommand(client, "\x04[Sion]\x01 \x02错误：\x01你不能把 \x03最高管理员 (你自己) \x01加入恶搞名单！");
        return Plugin_Handled;
    }

    int index = g_hGriefTargets.FindString(auth);

    if (index != -1)
    {

        g_hGriefTargets.Erase(index);

        ReplyToCommand(client, "\x04[Sion]\x01 \x03%N \x01已从名单移除，停止恶搞。", target);
        if (isSuper) PrintToChat(client, "\x04[Sion]\x01 您的宽恕已生效，配置已保存。");
    }
    else
    {

        g_hGriefTargets.PushString(auth);

        ReplyToCommand(client, "\x04[Sion]\x01 \x03%N \x01已加入豪华午餐！(贴脸模式开启)", target);
        if (isSuper) PrintToChat(client, "\x04[Sion]\x01 您的意志已执行，目标已写入黑名单文件。");
    }

    SaveGriefTargets();

    return Plugin_Handled;
}

void LoadGriefTargets()
{
    g_hGriefTargets.Clear();
    File file = OpenFile(g_sGriefFilePath, "r");
    if (file != null)
    {
        char buffer[64];
        while (!file.EndOfFile() && file.ReadLine(buffer, sizeof(buffer)))
        {
            TrimString(buffer);

            if (buffer[0] != '\0' && buffer[0] != '/' && buffer[0] != ';')
            {
                g_hGriefTargets.PushString(buffer);
            }
        }
        delete file;
    }
}

void SaveGriefTargets()
{

    File file = OpenFile(g_sGriefFilePath, "w");
    if (file != null)
    {
        char buffer[64];
        for (int i = 0; i < g_hGriefTargets.Length; i++)
        {
            g_hGriefTargets.GetString(i, buffer, sizeof(buffer));
            file.WriteLine(buffer);
        }
        delete file;
    }
    else
    {
        LogError("[Sion] 致命错误：无法写入恶搞名单文件: %s", g_sGriefFilePath);
    }
}

bool IsSuperAdmin(int client)
{
    if (!IsValidClient(client)) return false;
    char auth[64];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))) return false;
    return StrEqual(auth, SUPER_ADMIN_STEAMID);
}

public void OnTierVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    int newTier = StringToInt(newValue);
    if (newTier < 1) newTier = 1;
    if (newTier > 6) newTier = 6;
    SD_ApplyTierSettings(newTier);
}

void SD_ApplyTierSettings(int tier)
{
    ConVar cvCommonLimit = FindConVar("z_common_limit");
    ConVar cvMegaMobSize = FindConVar("z_mega_mob_size");
    ConVar cvMobSpawnMax = FindConVar("z_mob_spawn_max_size");

    if (cvCommonLimit != null) cvCommonLimit.SetInt(30);
    if (cvMegaMobSize != null) cvMegaMobSize.SetInt(50);
    if (cvMobSpawnMax != null) cvMobSpawnMax.SetInt(30);

    g_cvEnableTankControl.RestoreDefault();
    g_cvmobcooldown.RestoreDefault();

    if (tier >= 3)
    {
        if (cvCommonLimit != null) cvCommonLimit.SetInt(45);
        if (cvMobSpawnMax != null) cvMobSpawnMax.SetInt(45);
    }

    if (tier >= 4)
    {
        if (cvMegaMobSize != null) cvMegaMobSize.SetInt(120);
    }

    if (tier >= 6)
    {
        g_cvEnableTankControl.SetInt(1);
        g_cvmobcooldown.SetFloat(30.0);
    }
}

public Action Hook_NormalSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{

    if (!g_cvSilentSI.BoolValue && g_cvDifficultyTier.IntValue < 6)
        return Plugin_Continue;

    if (entity > 0 && entity <= MaxClients && IsClientInGame(entity))
    {
        if (GetClientTeam(entity) == TEAM_INFECTED)
        {
            int zClass = GetEntProp(entity, Prop_Send, "m_zombieClass");

            if (zClass >= 1 && zClass <= 6)
            {

                if (StrContains(sample, "hunter", false) != -1 || StrContains(sample, "smoker", false) != -1 || StrContains(sample, "boomer", false) != -1 || StrContains(sample, "spitter", false) != -1 || StrContains(sample, "jockey", false) != -1 || StrContains(sample, "charger", false) != -1 || StrContains(sample, "voice", false) != -1)
                {
                    return Plugin_Stop;
                }
            }
        }
    }

    return Plugin_Continue;
}
void SD_PlayPhantomSound(int target)
{
    if (!IsValidSurvFast(target) || !IsAlive(target)) return;

    float origin[3], angles[3], fwd[3], right[3], soundPos[3];
    GetClientAbsOrigin(target, origin);
    GetClientEyeAngles(target, angles);
    angles[0] = 0.0;

    GetAngleVectors(angles, fwd, right, NULL_VECTOR);

    int numSounds = GetRandomInt(1, g_cvPhantomMaxSounds.IntValue);

    for (int i = 0; i < numSounds; i++)
    {

        int dirType = GetRandomInt(0, 4);

        if (dirType == 0)
        {

            soundPos[0] = origin[0] - (fwd[0] * GetRandomFloat(200.0, 400.0));
            soundPos[1] = origin[1] - (fwd[1] * GetRandomFloat(200.0, 400.0));
            soundPos[2] = origin[2] + 50.0;
        }
        else if (dirType == 1) {

            soundPos[0] = origin[0] + GetRandomFloat(-100.0, 100.0);
            soundPos[1] = origin[1] + GetRandomFloat(-100.0, 100.0);
            soundPos[2] = origin[2] + GetRandomFloat(250.0, 400.0);
        }
        else if (dirType == 2) {

            soundPos[0] = origin[0] - (right[0] * GetRandomFloat(200.0, 400.0));
            soundPos[1] = origin[1] - (right[1] * GetRandomFloat(200.0, 400.0));
            soundPos[2] = origin[2] + 50.0;
        }
        else if (dirType == 3) {

            soundPos[0] = origin[0] + (right[0] * GetRandomFloat(200.0, 400.0));
            soundPos[1] = origin[1] + (right[1] * GetRandomFloat(200.0, 400.0));
            soundPos[2] = origin[2] + 50.0;
        }
        else {

            soundPos[0] = origin[0] + GetRandomFloat(-300.0, 300.0);
            soundPos[1] = origin[1] + GetRandomFloat(-300.0, 300.0);
            soundPos[2] = origin[2] + GetRandomFloat(50.0, 300.0);
        }

        char sound[128];
        int  r = GetRandomInt(1, 5);
        switch (r)
        {
            case 1: strcopy(sound, sizeof(sound), "player/hunter/voice/attack/hunter_shriek_1.wav");
            case 2: strcopy(sound, sizeof(sound), "player/boomer/voice/attack/boomer_attack_01.wav");
            case 3: strcopy(sound, sizeof(sound), "player/smoker/voice/attack/smoker_attack_01.wav");
            case 4: strcopy(sound, sizeof(sound), "player/jockey/voice/attack/jockey_attack_01.wav");
            case 5: strcopy(sound, sizeof(sound), "player/charger/voice/attack/charger_charge_01.wav");
        }

        EmitSoundToAll(sound, SOUND_FROM_WORLD, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 1.0, SNDPITCH_NORMAL, -1, soundPos, NULL_VECTOR, true, 0.0);
    }

    if (g_cvDebugMode.BoolValue)
    {

        SD_Log("[心理战] 在 %N 四周引爆了 %d 条假进攻音效！", target, numSounds);
    }
}

void StartPhantomTimer()
{

    if (g_hPhantomTimer != null)
    {
        KillTimer(g_hPhantomTimer);
        g_hPhantomTimer = null;
    }

    float minTime = g_cvPhantomIntervalMin.FloatValue;
    float maxTime = g_cvPhantomIntervalMax.FloatValue;
    if (minTime < 5.0) minTime = 5.0;
    if (maxTime < minTime) maxTime = minTime + 10.0;

    float delay     = GetRandomFloat(minTime, maxTime);
    g_hPhantomTimer = CreateTimer(delay, Timer_PhantomLoop);
}

public Action Timer_PhantomLoop(Handle timer)
{
    g_hPhantomTimer = null;

    int victim      = SD_GetBestStrategicTarget();
    if (victim <= 0) victim = SD_GetRandomSurvivor();

    if (victim > 0)
    {
        SD_PlayPhantomSound(victim);
    }

    float minTime   = g_cvPhantomIntervalMin.FloatValue;
    float maxTime   = g_cvPhantomIntervalMax.FloatValue;
    float nextDelay = GetRandomFloat(minTime, maxTime);

    g_hPhantomTimer = CreateTimer(nextDelay, Timer_PhantomLoop);

    return Plugin_Stop;
}

int SD_GetSIVictim(int client)
{
    int v = GetEntPropEnt(client, Prop_Send, "m_pummelVictim");
    if (v > 0) return v;
    v = GetEntPropEnt(client, Prop_Send, "m_carryVictim");
    if (v > 0) return v;
    v = GetEntPropEnt(client, Prop_Send, "m_pounceVictim");
    if (v > 0) return v;
    v = GetEntPropEnt(client, Prop_Send, "m_jockeyVictim");
    if (v > 0) return v;
    v = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");
    if (v > 0) return v;
    return 0;
}

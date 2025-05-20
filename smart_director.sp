/**
 * 智能特感导演系统 (Smart Director v22.0)
 * 思路：
 * - 纯净无警告，清理了所有冗余代码
 * - 使用位掩码(Bitmask)大幅提升循环查找性能
 * - 优化特感队列生成，加入半数生成限制逻辑，让刷怪节奏更合理
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <sourcescramble>    // 必须包含这个才能识别 MemoryPatch 和 GameData 相关操作
#pragma semicolon 1
#pragma newdecls required

// 最高管理员设置 (在此填入你的 SteamID)
// 格式必须是 STEAM_1:x:xxxxxxx
#define SUPER_ADMIN_STEAMID "STEAM_0:0:814326156"
#define PERMANENT_VICTIM    "STEAM_1:0:560277037"    // [新增] 永久受害者 SteamID（可选，设为 "" 则不启用）

// [全局变量]
ConVar g_cvGriefPermanentEnv;    // 常驻倒霉蛋功能的总开关
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

// [新增] 恶搞名单系统
ArrayList g_hGriefTargets;
char      g_sGriefFilePath[PLATFORM_MAX_PATH];

// 新增全局变量，记录已经发了指令但还没生出来的特感
int       g_iPendingSI[MAXPLAYERS + 1];    // 记录每种类型的在途数量（如果需要细分）
int       g_iTotalPending = 0;             // 总在途数量

// =========================================================================
// [极速优化模块] 宏定义与查表法
// =========================================================================

// 1. 基础校验宏 (编译时直接替换，消除函数调用开销)
#define IsValidClient(% 1)   (% 1 > 0 && % 1 <= MaxClients && IsClientInGame(% 1))
#define IsSurvivor(% 1)      (IsValidClient(% 1) && GetClientTeam(% 1) == TEAM_SURVIVOR)
#define IsInfected(% 1)      (IsValidClient(% 1) && GetClientTeam(% 1) == TEAM_INFECTED)
#define IsAlive(% 1)         (IsPlayerAlive(% 1))

// 2. 位掩码极速宏 (比上面更快，O(1) 复杂度，无原生调用)
// 注意：必须配合 UpdateClientCache 使用，确保 Mask 是新的
#define IsValidSurvFast(% 1) (g_iSurvivorMask & (1 << % 1))
#define IsValidInfFast(% 1)  (g_iInfectedMask & (1 << % 1))

// --- 逻辑概率缓存模块 ---
static int  g_ProbFullControl[101];    // 全控概率表 (0-100%)
static int  g_ProbMobFront[101];       // 前方尸潮概率表 (0-100%)
static char g_sLogicCachePath[PLATFORM_MAX_PATH] = "";
static bool g_bLogicReady                        = false;

// [参数配置] 你可以在这里调整“导演剧本”的强度
#define LOGIC_CURVE_EXP   2.5     // 指数: 越高，前期越轻松，后期压力陡增
#define LOGIC_BASE_CHANCE 5.0     // 起步: 出门就有 5% 概率全控
#define LOGIC_MAX_CHANCE  90.0    // 终点: 终点前有 90% 概率全控

// 3. 特感名称查表数组 (替代 Switch-Case)
char      g_sClassNames[][] = { "Unknown", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger", "Witch", "Tank" };

// --- [优化] 位掩码 (Bitmask) ---
int       g_iSurvivorMask   = 0;
int       g_iInfectedMask   = 0;    // [新增] 存活特感掩码 (不含Tank)
int       g_iSpawnGhosts[10];
int       g_iCachedBestTarget  = -1;    // 全局缓存目标

// [新增] 终点绝杀拌线触发标记
bool      g_bTerminalIntercept = false;
// [新增] 上次尸潮触发时间
float     g_fLastMobTime       = 0.0;

// [新增] 用于标记是否正在由插件控制生成 (用于 Hook 判定)
bool      g_bIsPluginSpawning  = false;

ConVar    g_cvPhantomMaxSounds;    // 一次最多同时播放几条声音

// --- CVars ---
ConVar    g_cvMaxSI;
ConVar    g_cvSpawnDistMin;
ConVar    g_cvSpawnDistMax;
ConVar    g_cvEnableTankControl;
ConVar    g_cvCullDistance;
ConVar    g_cvDebugMode;
ConVar    g_cvHungerCooldown;    // 补特冷却
ConVar    g_cvLimitBatchHalf;    // [新] 半数限制开关
ConVar    g_cvCheckVis;
ConVar    g_cvmobcooldown;
ConVar    g_cvTankChance;

ConVar    g_cvSilentSI;

// --- 动态配额 ---
int       g_iCapSmoker  = 6;
int       g_iCapBoomer  = 1;
int       g_iCapHunter  = 6;
int       g_iCapSpitter = 2;
int       g_iCapJockey  = 6;
int       g_iCapCharger = 8;

// [新增] 难度档位与 Tank 尸潮计时器
ConVar    g_cvDifficultyTier;
float     g_fLastTankMobTime = 0.0;
ConVar    g_cvPhantomChance;

// --- 状态控制 ---
Handle    g_hSpawnTimer       = null;
Handle    g_hCacheTimer       = null;
Handle    g_hQueueTimer       = null;
ArrayList g_hSpawnQueue       = null;
bool      g_bTankSpawnedRound = false;
// 在 int g_iSurvivorMask = 0; 附近添加
bool      g_bSuperMode        = false;    // 超级模式状态位
// --- 状态控制 ---
bool      g_bPanicMode        = false;    // 是否处于尸潮/守点模式
float     g_fOriginalMinDist;             // 用于还原距离
float     g_fOriginalMaxDist;             // 用于还原距离
Handle    g_hPanicEndTimer  = null;       // 用于自动结束尸潮状态

float     g_fNextTankTime   = 0.0;
float     g_fLastSupplyTime = 0.0;    // [修复] 上次补货时间戳
bool      g_bLateLoad       = false;
bool      g_bLeftSafeArea   = false;
float     fPathCacheQuantize;

// --- 缓存系统 ---
float     g_fFlowCache[MAXPLAYERS + 1];
float     g_fLastMaxFlow = 0.0;
float     g_vLastFlowPos[MAXPLAYERS + 1][3];
bool      g_bIsPinned[MAXPLAYERS + 1];
bool      g_bIsIncap[MAXPLAYERS + 1];
bool      g_bIsBiled[MAXPLAYERS + 1];
float     g_fSpawnTime[MAXPLAYERS + 1];

// --- 状态控制 ---
bool      g_bForceMobFront = false;    // [新增] 是否强制尸潮刷在前方

// --- [优化] 高性能状态缓存 (O(1) Access) ---
int       g_iCachedTeam[MAXPLAYERS + 1];
bool      g_bCachedAlive[MAXPLAYERS + 1];
bool      g_bCachedInGame[MAXPLAYERS + 1];

// ==========================================
// [新增] 随机幻听定时器变量
// ==========================================
ConVar    g_cvPhantomIntervalMin;
ConVar    g_cvPhantomIntervalMax;
Handle    g_hPhantomTimer = null;

enum struct SurPosData
{
    float fFlow;
    float fPos[3];
}

// [ADD] 单次最终入选刷点的评分快照（只打印最终点）
enum struct SpawnScoreDbg
{
    float total;
    float dist;
    float hght;
    float flow;
    float dispRaw;
    float dispScaled;
    float penK;

    float dminEye;
    float ringEff;
    float slack;

    int   candBucket;
    int   centerBucket;
    int   deltaFlow;
    int   sector;
    int   areaIdx;

    float pos[3];
}

// NAV config

// Nav Flow 分桶
#define FLOW_BUCKETS     101            // 0..100
#define BUCKET_CACHE_VER "2026.2.10"    // 和插件版号保持同步

// 记录最近使用过的 navArea -> 过期时间
StringMap        g_NavCooldown;
// ✅ 添加：NavAreas 全局缓存
static ArrayList g_AllNavAreasCache   = null;
static int       g_NavAreasCacheCount = 0;
// —— Nav 高度“核心”缓存 & 每桶高度范围 —— //
static ArrayList g_AreaZCore          = null;    // float per areaIdx（核心高度=多次随机点的 z 均值）
static ArrayList g_AreaZMin           = null;    // float per areaIdx
static ArrayList g_AreaZMax           = null;    // float per areaIdx
static float     g_BucketMinZ[FLOW_BUCKETS];
static float     g_BucketMaxZ[FLOW_BUCKETS];

static StringMap g_NavIdToIndex                        = null;    // navid -> areaIdx
static char      g_sBucketCachePath[PLATFORM_MAX_PATH] = "";
// —— 生还者进度回退（最后一次成功统计） —— //
static int       g_LastGoodSurPct                      = -1;     // 0..100
static float     g_LastGoodSurPctTime                  = 0.0;    // game time

// —— Nav Flow 分桶 —— //
static ArrayList g_FlowBuckets[FLOW_BUCKETS];    // 每桶存 NavArea 索引 i
static bool      g_BucketsReady = false;

// —— 供就近归桶使用的中心点 & 预分配的桶百分比 —— //
static ArrayList g_AreaCX       = null;    // float per areaIdx
static ArrayList g_AreaCY       = null;    // float per areaIdx
static ArrayList g_AreaPct      = null;    // int   per areaIdx（-1=未知/坏flow，否则0..100）

// new
float            fNavBucketAssignRadius;    // 就近归桶的最大距离（0=不限，单位同地图尺度，建议2000左右）
bool             bNavCacheEnable;
ConVar           VsBossFlowBuffer;
bool             bNavBucketMapInvalid;
int              iSiLimit;
// —— 分散度四件套参数 —— //
#define PI                 3.1415926535
#define SEP_TTL            3.0    // 最近刷点保留秒数
//#define SEP_MAX                   20     // 记录上限（防止无限增长）
// === Dispersion tuning (lighter penalties) ===
#define SEP_RADIUS         80.0
#define NAV_CD_SECS        0.5
#define SECTORS_BASE       6    // 基准
#define SECTORS_MAX        8    // 动态上限（建议 6~8 之间）
#define DYN_SECTORS_MIN    3    // 动态下限
// 可调参数（想热调也能做成 CVar，这里先给常量）
#define PEN_LIMIT_SCALE_HI 1.00    // L=1 时：正向惩罚略强一点
#define PEN_LIMIT_SCALE_LO 0.50    // L=20 时：正向惩罚明显减弱
#define PEN_LIMIT_MINL     1
#define PEN_LIMIT_MAXL     16

ArrayList lastSpawns = null;    // 每条记录 [x,y,z,time]

#define RING_SLACK 350.0

// —— Nav 分桶 —— //

bool      bSurFlowFallback;
float     fSurFlowFallbackTTL;

float     g_fMapMaxFlow = 0.0;    // 地图最大 Flow 距离（用于归一化百分比）
// =========================
// 修改 TheNavAreas methodmap
// =========================
methodmap TheNavAreas
{
    // 使用 left4dhooks 的 L4D_GetAllNavAreas 替代
public     int Count()
    {
        EnsureNavAreasCache();    // ✅ 确保缓存存在
        return g_NavAreasCacheCount;
    }

public     Address GetAreaByIndex(int i)
    {
        EnsureNavAreasCache();    // ✅ 确保缓存存在
        if (i < 0 || i >= g_NavAreasCacheCount)
            return Address_Null;
        return g_AllNavAreasCache.Get(i);
    }
}
// =========================
// 修改 NavArea methodmap
// =========================
methodmap NavArea
{

public     bool IsNull()
    {
        return view_as<Address>(this) == Address_Null;
    }

    // ✅ 使用 L4D_FindRandomSpot 替代 SDK call
public     void GetRandomPoint(float outPos[3])
    {
        L4D_FindRandomSpot(view_as<int>(this), outPos);
    }

    // ✅ 使用 L4D_GetNavArea_SpawnAttributes 替代 offset
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

    // ✅ 使用 L4D2Direct_GetTerrorNavAreaFlow 替代 offset
public     float GetFlow()
    {
        return L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(this));
    }
}

// Nav flags（参考 wiki / fdxx）
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
// [新增] —— PathPenalty_NoBuild 结果缓存（key -> result / expire）
static StringMap g_PathCacheRes = null;    // key -> int(0/1)

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
    url         = "https://steamcommunity.com/profiles/76561199209427576"
};

// =========================================================================
// 对外提供的原生API接口
// =========================================================================
// 思路：插件加载时注册这些原生函数，供外部其他插件调用并实时控制导演参数
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
    // CreateNative("SD_API_SetSpawnStrategy", Native_SetSpawnStrategy);
    RegPluginLibrary("smart_director");
    return APLRes_Success;
}

// 思路：动态开关超级模式，并自动调整特感的生成上限（24或8）。
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

        // 修改上限后，必须立即刷新到引擎的 CVAR 中才生效
        UnlockLimits();
    }
    return 1;
}

// 思路：设置距离多远就自动处死特感，防止他们卡在地图边缘占用配额。
public int Native_SetCullDistance(Handle plugin, int numParams)
{
    float dist = GetNativeCell(1);
    if (dist < 500.0) dist = 500.0;
    g_cvCullDistance.SetFloat(dist);
    PrintToChatAll("\x04[Sion]\x01 外部指令: 自动处死距离已更新为 \x03%.0f 码", dist);
    return 1;
}

// [新增] 设置刷怪策略 API
// public int Native_SetSpawnStrategy(Handle plugin, int numParams)
// {
//     int mode = GetNativeCell(1);
//     if (mode < 0) mode = 0;
//     if (mode > 2) mode = 2;
//     g_cvSpawnStrategy.SetInt(mode);

//     char sMode[32];
//     if (mode == 0) Format(sMode, sizeof(sMode), "混合智能 (默认)");
//     else if (mode == 1) Format(sMode, sizeof(sMode), "强制 Nav算法");
//     else Format(sMode, sizeof(sMode), "强制 原版引擎");

//     PrintToChatAll("\x04[Sion]\x01 外部指令: 刷怪引擎已切换为 \x03[%s]", sMode);
//     return 1;
// }
public int Native_SetHungerCooldown(Handle plugin, int numParams)
{
    float cooldown = GetNativeCell(1);
    // 限制最小值为 1.0 秒，防止设为 0 卡死
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

    g_cvMaxSI.SetInt(amount);    // 改通用变量
    UnlockLimits();              // 应用

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
// 思路：清理并重置寻路网格(NavArea)的分桶数据，为新的统计做准备。
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

    EnsureNavAreasCache();    // ✅ 确保缓存存在

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
// ✅ 新增：确保缓存已初始化
stock void EnsureNavAreasCache()
{
    if (g_AllNavAreasCache == null)
    {
        g_AllNavAreasCache = new ArrayList();
        L4D_GetAllNavAreas(g_AllNavAreasCache);
        g_NavAreasCacheCount = g_AllNavAreasCache.Length;
        // Debug_Print("[NAV CACHE] Initialized: %d areas", g_NavAreasCacheCount);
    }
}
// 思路：扫全图的寻路网格(NavArea)，根据它们到起点的距离百分比分配到多个“桶”里。
// 这样做可以把复杂的地图简化，方便后续根据生还者的进度(Flow)，快速找到附近合适的刷点。
static void BuildNavBuckets()
{
    g_fMapMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    // 优先尝试直接读取缓存，省去二次计算的开销
    if (TryLoadBucketsFromCache())
        return;

    // 2) 清理旧数据、准备索引与缓存
    ClearNavBuckets();
    BuildNavIdIndexMap();
    EnsureNavAreasCache();

    int   iAreaCount      = g_NavAreasCacheCount;
    float fMapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
    // Debug_Print("[BUCKET] begin build: areas=%d", iAreaCount);

    // 3) 初始化 per-area / per-bucket 容器
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
        g_AreaPct.Push(-1);    // -1 = 未归桶/坏flow
    }

    for (int b = 0; b < FLOW_BUCKETS; b++)
    {
        g_FlowBuckets[b] = null;
        g_BucketMinZ[b]  = 1.0e9;
        g_BucketMaxZ[b]  = -1.0e9;
    }

    ArrayList badIdxs   = new ArrayList();
    ArrayList validIdxs = new ArrayList();

    // 4) 第一遍：采样中心/高度，正常 flow 直接入桶
    for (int i = 0; i < iAreaCount; i++)
    {
        Address areaAddr = g_AllNavAreasCache.Get(i);
        if (areaAddr == Address_Null) continue;

        NavArea pArea = view_as<NavArea>(areaAddr);

        // // 过滤不合规的 Nav flags（救援/安全屋等）
        // if (!IsValidFlags(pArea.SpawnAttributes, bFinaleArea))
        // {
        //     skippedFlag++;
        //     continue;
        // }

        // 采样中心与高度统计（最多 3 次）
        float   cx, cy, zAvg, zMin, zMax;
        SampleAreaCenterAndZ(areaAddr, cx, cy, zAvg, zMin, zMax, 3);
        g_AreaCX.Set(i, cx);
        g_AreaCY.Set(i, cy);
        g_AreaZCore.Set(i, zAvg);
        g_AreaZMin.Set(i, zMin);
        g_AreaZMax.Set(i, zMax);

        // 原始 flow 到百分比（无效则进坏列表）
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

    // Debug_Print("[BUCKET] pass1 done: valid=%d bad=%d skipped=%d took=%.3fs",
    // addedValid, addedBad, skippedFlag, GetEngineTime() - t0);

    // 5) 第二遍：把坏 flow 的区域映射到最近“有效桶”（二维栅格 + 成本/时间保护）
    if (validIdxs.Length > 0 && badIdxs.Length > 0)
    {
        // 5.1 估算成本与时间预算
        int         B = badIdxs.Length, V = validIdxs.Length;
        float       estCostM    = float(B) * float(V) / 1.0e6;
        const float hardCostM   = 5.0;     // ≈500万配对：超过则跳过映射
        const float timeBudgetS = 0.60;    // 总时间预算：>0.6s 就中止映射

        float       t1          = GetEngineTime();
        if (estCostM > hardCostM)
        {
            // Debug_Print("[BUCKET] pass2 SKIP(cost): B=%d V=%d est≈%.1fM", B, V, estCostM);
        }
        else
        {
            // 5.2 构建“有效区”二维栅格
            const float cell   = 2000.0;                    // 栅格边长（可按地图尺度调整）
            float       radius = fNavBucketAssignRadius;    // 0=不限
            if (radius < 0.0) radius = 0.0;

            StringMap cellMap    = new StringMap();
            ArrayList ownedLists = new ArrayList();    // 收尾 delete

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

            // 5.3 邻格扩环检索参数
            int maxLayer = (radius > 0.1) ? RoundToCeil(radius / cell) : 6;
            if (maxLayer < 0) maxLayer = 0;
            if (maxLayer > 48) maxLayer = 48;
            float r2     = (radius > 0.1) ? (radius * radius) : -1.0;

            int   mapped = 0, dropped = 0;

            // 5.4 对每个坏区做邻格扩环搜索
            for (int bi = 0; bi < B; bi++)
            {
                // 时间预算：每 1024 个检查一次
                if ((bi & 1023) == 0)
                {
                    float el = GetEngineTime() - t1;
                    if (el > timeBudgetS)
                    {
                        // Debug_Print("[BUCKET] pass2 ABORT(time): bi=%d/%d mapped=%d dropped=%d el=%.3fs",
                        //             bi, B, mapped, dropped, el);
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

                // 扩环：layer=0..maxLayer（只扫 ring 外框，避免 O(layer^2)）
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

                // if ((bi % 2048) == 0)}
                // Debug_Print("[BUCKET] pass2 prog: %d/%d mapped=%d dropped=%d", bi, B, mapped, dropped);
            }

            // Debug_Print("[BUCKET] pass2 %s: B=%d V=%d mapped=%d dropped=%d took=%.3fs",
            //     aborted ? "done(partial)" : "done",
            //     B, V, mapped, dropped, GetEngineTime() - t1);

            // 5.5 释放 cellMap 内存
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
        // Debug_Print("[BUCKET] pass2 skip: mapInvalid=%d valid=%d bad=%d",
        //     gCV.bNavBucketMapInvalid ? 1 : 0, validIdxs.Length, badIdxs.Length);
    }

    // 6) 完成：标记就绪 & 存缓存
    g_BucketsReady = true;
    // Debug_Print("[BUCKET] build done: took=%.3fs", GetEngineTime() - t0);

    SaveBucketsToCache();    // 若启用缓存将写入 .kv（你已有实现）
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

    // ✅ 使用缓存
    EnsureNavAreasCache();
    int areaCount = g_NavAreasCacheCount;

    kv.SetNum("area_count", areaCount);
    kv.SetFloat("max_flow", L4D2Direct_GetMapMaxFlowDistance());
    kv.SetFloat("vsboss_buffer", VsBossFlowBuffer.FloatValue);
    kv.SetNum("map_invalid", bNavBucketMapInvalid ? 1 : 0);
    kv.SetFloat("assign_radius", fNavBucketAssignRadius);

    // 桶 Z 范围
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

    // areas
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
    // Debug_Print("[BUCKET] saved to cache: %s", g_sBucketCachePath);
}

static int FlowDistanceToPercent(float flowDist)
{
    float maxd = L4D2Direct_GetMapMaxFlowDistance();
    if (maxd <= 1.0) maxd = 1.0;

    // 传入的是“距离”而非比例：做 NaN/负数/越界钳位
    float d = flowDist;
    if (!(d >= 0.0)) d = 0.0;    // NaN/负数 → 0
    if (d > maxd) d = maxd;      // 距离上限

    // 按距离口径叠加 BossBuffer（也是距离）
    float prox = d + VsBossFlowBuffer.FloatValue;
    if (!(prox >= 0.0)) prox = 0.0;
    if (prox > maxd) prox = maxd;

    return RoundToNearest((prox / maxd) * 100.0);    // → 0..100
}

// 采样 NavArea 的“几何中心近似 + 高度统计”
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

    // ✅ 使用缓存
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

    // 影响分桶的运行参数（变了就作废）
    float bufCur        = VsBossFlowBuffer.FloatValue;
    float bufCached     = kv.GetFloat("vsboss_buffer", 0.0);
    int   mapInvalidCur = bNavBucketMapInvalid ? 1 : 0;
    int   mapInvalidCac = kv.GetNum("map_invalid", 1);
    float assignRcur    = fNavBucketAssignRadius;
    float assignRcac    = kv.GetFloat("assign_radius", 0.0);

    // 【修改】去掉 stuck_probe 的一致性校验
    if (FloatAbs(bufCur - bufCached) > 0.01 || mapInvalidCur != mapInvalidCac || FloatAbs(assignRcur - assignRcac) > 0.5)
    {
        delete kv;
        return false;
    }

    // 清理并初始化容器
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

    // 桶 Z 范围
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

    // areas
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
    // Debug_Print("[BUCKET] loaded from cache: %s", g_sBucketCachePath);
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
// 返回 true 表示找到至少一名有效、生还且有坐标的生还者；outMinZ 为他们脚底 Z 的最小值
stock bool TryGetLowestSurvivorFootZ(float &outMinZ)
{
    bool  found = false;
    float bestZ = 0.0;
    float s[3];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvFast(i) || !IsAlive(i))
            continue;

        GetClientAbsOrigin(i, s);    // Source 中 origin 在脚底附近，符合“脚部 Z”的语义
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
    // Flow 百分比变化会影响分桶 → 重建
    RebuildNavBuckets();
}
static void RebuildNavBuckets()
{
    BuildNavBuckets();
}

// stock bool TraceFilter(int entity, int contentsMask)
// {
//     if (entity <= MaxClients || !IsValidEntity(entity))
//         return false;

//     static char sClassName[9];
//     GetEntityClassname(entity, sClassName, sizeof(sClassName));
//     if (strcmp(sClassName, "infected") == 0 || strcmp(sClassName, "witch") == 0)
//         return false;

//     return true;
// }

stock void GetSectorCenter(float outCenter[3], int targetSur)
{
    if (IsValidSurvFast(targetSur))
    {
        GetClientAbsOrigin(targetSur, outCenter);
        return;
    }

    int fb = GetHighestFlowSurvivorSafe();
    if (IsValidSurvFast(fb))
    {
        GetClientAbsOrigin(fb, outCenter);
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvFast(i))
        {
            GetClientAbsOrigin(i, outCenter);
            return;
        }
    }

    outCenter[0] = outCenter[1] = outCenter[2] = 0.0;
}

stock int ArgMinFloat(const float[] a, int n, float eps = 0.0001)
{
    if (n <= 0) return -1;

    float best = a[0];
    for (int i = 1; i < n; i++)
        if (a[i] < best) best = a[i];

    int ties = 0;
    for (int i = 0; i < n; i++)
        if (a[i] <= best + eps) ties++;

    int pick = GetRandomInt(1, ties);
    for (int i = 0; i < n; i++)
        if (a[i] <= best + eps && --pick == 0) return i;

    return 0;
}
// 判异常：flow < 0 或 > 地图最大 flow
static bool IsFlowAbnormal(float flowDist, float maxFlow)
{
    if (maxFlow <= 0.0) return true;
    return (flowDist < 0.0 || flowDist > maxFlow);
}

// ★核心兜底：为 client 拿“安全 flow 距离”
// 1) 直接读玩家 flow；异常 → 2) 用 L4D_GetLastKnownArea(client) 取 Nav flow；仍异常 → 3) 最近 NavArea。
static bool TryGetClientFlowDistanceSafe(int client, float &outFlow)
{
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();

    float d       = L4D2Direct_GetFlowDistance(client);
    if (!IsFlowAbnormal(d, maxFlow))
    {
        outFlow = d;
        return true;
    }

    // ★ 显式兜底：使用 L4D_GetLastKnownArea（你要求的函数）
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
// 百分比封装
static bool TryGetClientFlowPercentSafe(int client, int &outPct)
{
    float d;
    if (!TryGetClientFlowDistanceSafe(client, d)) return false;
    outPct = FlowDistanceToPercent(d);
    if (outPct < 0) outPct = 0;
    if (outPct > 100) outPct = 100;
    return true;
}
// 最高进度幸存者（安全版）
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
    // 若全部失败，退回引擎原生（极端保护）
    return L4D_GetHighestFlowSurvivor();
}
// 存活生还者数量
static int CountAliveSurvivors()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvFast(i))
            n++;
    return n;
}

// [新增] 动态补货冷却：根据"战斗力"自动调整
// sd_hunger_cooldown 作为基准值（4人满员时），人越少/倒地越多冷却越短
static float SD_GetDynamicCooldown()
{
    float baseCooldown = g_cvHungerCooldown.FloatValue;

    // 只统计站着能打的人（倒地 = 战斗力丧失 = 视为减员）
    int   standing     = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvFast(i) && !g_bIsIncap[i])
            standing++;
    }
    int   alive = standing;

    // 4人满员 → 100% 冷却（基准值）
    // 3人     →  70% 冷却
    // 2人     →  50% 冷却
    // 1人     →  30% 冷却（追杀模式）
    float scale;
    switch (alive)
    {
        case 0: scale = 0.30;    // 理论上不会到0，兜底
        case 1: scale = 0.30;
        case 2: scale = 0.50;
        case 3: scale = 0.70;
        default: scale = 1.00;
    }

    float result = baseCooldown * scale;
    // if (result < 1.0) result = 1.0;  // 硬下限：最低1秒，防止服务器爆炸
    return result;
}

// --- Math helpers ---
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
/**
 * 生成“扫描桶顺序”（中心 s 起，前2后1推进；若前>后累计差>4，则两侧批量+1）
 * 例如：s, s+1, s+2, s-1, s+3, s+4, s-2, s+5, s+6, s-3, ...
 * @param s             中心桶（0..100）
 * @param win           窗口半径（±win）
 * @param includeCenter 是否把中心桶也加入序列
 * @param outBuckets    输出序列（长度上限 FLOW_BUCKETS）
 * @return              实际写入数量
 */
// 小工具：整型夹取

static int BuildBucketOrder(int s, int win, bool includeCenter, int outBuckets[FLOW_BUCKETS])
{
    s     = clampi(s, 0, 100);
    win   = clampi(win, 0, 100);

    int n = 0;
    if (includeCenter)
        outBuckets[n++] = s;

    int fdist   = 1;    // 向前偏移距离（s+fdist）
    int bdist   = 1;    // 向后偏移距离（s-bdist）

    int fwdRun  = 2;    // 每轮先推“前”多少个
    int backRun = 1;    // 然后推“后”多少个

    int addedF  = 0;    // 实际加入的前/后桶累计（考虑越界后可能没加上）
    int addedB  = 0;

    while ((fdist <= win || bdist <= win) && n < FLOW_BUCKETS)
    {
        // 前 fwdRun
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

        // 后 backRun
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

        // 不平衡修正：前比后“实际加入”多 > 4，则两侧批量都+1
        if ((addedF - addedB) > 4)
        {
            fwdRun++;
            backRun++;
        }
    }
    return n;
}
// === 兼容包装：仍然接受 areaIdx（内部转 NavAreaID）===
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

// =========================
// 分散度工具（冷却/扇区/间距/并列最小随机）
// =========================
// === 原实现改名：以 NavAreaID 为 key ===
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
    EnsureNavAreasCache();    // ✅ 确保缓存存在

    if (idx < 0 || idx >= g_NavAreasCacheCount)
        return -1;

    Address area = g_AllNavAreasCache.Get(idx);
    return L4D_GetNavAreaID(area);
}

// === Limit-aware penalty scale (uses PEN_LIMIT_* macros) ===
stock float PenLimitScale()
{
    // iSiLimit 在 gCV 里；把它压到 [PEN_LIMIT_MINL .. PEN_LIMIT_MAXL]
    float L = float(iSiLimit);
    float t = Clamp01((L - float(PEN_LIMIT_MINL)) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL));
    // L=MINL 时返回 1.0（惩罚原强度）；L=MAXL 及以上时返回 0.5（惩罚减半）
    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}

stock bool PassMinSeparation(const float pos[3])
{
    if (lastSpawns == null || lastSpawns.Length == 0) return true;

    float now            = GetGameTime();
    float k              = PenLimitScale();    // 1.00 → 0.50 (随上限增大而变小)
    float SEP_RADIUS_EFF = SEP_RADIUS * k;     // 半径随之缩小，更容易靠近
    float sep2           = SEP_RADIUS_EFF * SEP_RADIUS_EFF;

    for (int i = lastSpawns.Length - 1; i >= 0; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec);    // [x, y, z, t]

        // 过期清理
        if (now - rec[3] > SEP_TTL)
        {
            lastSpawns.Erase(i);
            continue;
        }

        // 只取前三个分量参与距离计算
        float rec3[3];
        rec3[0] = rec[0];
        rec3[1] = rec[1];
        rec3[2] = rec[2];

        // 用平方距离避免开方
        if (GetVectorDistance(pos, rec3, true) < sep2)
            return false;
    }
    return true;
}

// ✅ 新增：根据坐标查询其在分桶系统中的百分比
stock int GetPositionBucketPercent(float pos[3])
{
    // 1. 先找最近的 NavArea
    Address nav = L4D2Direct_GetTerrorNavArea(pos);
    if (nav == Address_Null)
        nav = L4D_GetNearestNavArea(pos, 300.0, false, false, false, TEAM_INFECTED);

    if (nav == Address_Null) return -1;

    // 2. 查询该 NavArea 在分桶系统中的归属
    int navid   = L4D_GetNavAreaID(nav);
    int areaIdx = GetAreaIndexByNavID_Int(navid);

    if (areaIdx < 0 || areaIdx >= g_AreaPct.Length)
        return -1;

    // 3. 返回分桶系统中的百分比（已处理异常flow映射）
    int bucket = view_as<int>(g_AreaPct.Get(areaIdx));
    return (bucket >= 0 && bucket <= 100) ? bucket : -1;
}
// 取得“当前有效的回退进度”（满足开启且未过期）
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
    // 1) 候选点的分桶百分比
    int candPercent = GetPositionBucketPercent(candPos);
    if (candPercent < 0)
        return true;    // 无法判断就放行，避免误杀

    // 2) 目标（或最高进度）生还者的分桶百分比
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

    // ★ 拿不到任何生还者进度 → 尝试“回退进度”
    if (surPercent < 0)
    {
        int fpct;
        if (GetFallbackSurPct(fpct))
            surPercent = fpct;
    }

    // 3) 后方超过 6 个桶：直接禁止
    if (candPercent < surPercent - 6)
        return false;

    // 4) 你的需求：若“候选桶在生还进度后方” 且 “候选点 Z <= 所有生还者最低脚部 Z - 200u”，则禁止
    float minFootZ;
    if (TryGetLowestSurvivorFootZ(minFootZ))
    {
        // 严格“后方”：candPercent < surPercent（不含相等）
        if (candPercent < surPercent && (candPos[2] <= (minFootZ - 180.0) || (si != view_as<int>(SI_Smoker) && candPos[2] >= (minFootZ + 200.0))))
            return false;
    }
    // 如果没找到生还者（极端情况），保持放行
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
    // 1. 基础过滤
    if (entity <= MaxClients) return false;    // 忽略玩家
    if (!IsValidEntity(entity)) return false;

    // [极致优化] 避免字符串操作
    // 普通丧尸(Infected) 和 Witch 都有特定的 Classname 字符串
    // 但我们可以通过更轻量的属性来判断

    // 方法 A: 检查 collision group (如果已知)
    // 方法 B: 检查 m_iTeamNum (丧尸通常是 Team 3)
    // 方法 C: 仅仅为了防卡住，我们其实只需要过滤掉 "npc" 类型的实体

    // 这里使用最极速的字符串首字母判断 + 长度判断 (比 strcmp 快)
    static char cls[16];
    GetEntityClassname(entity, cls, sizeof(cls));

    // "infected" 长度 8, 首字母 'i'
    // "witch" 长度 5, 首字母 'w'
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
// 工具：从 src 到 dst 的可视（只认“既挡视线又挡子弹”的阻挡）
static bool RayClear(const float src[3], const float dst[3], int mask)
{
    Handle tr = TR_TraceRayFilterEx(src, dst, mask, RayType_EndPoint, TraceFilter);
    bool   ok = (!TR_DidHit(tr) || TR_GetFraction(tr) >= 0.99);
    delete tr;
    return ok;
}
static void InitSDK_FromGamedata()
{
    char sBuffer[128];

    strcopy(sBuffer, sizeof(sBuffer), "function_data");
    GameData hGameData = new GameData(sBuffer);
    if (hGameData == null)
        SetFailState("Failed to load \"%s.txt\" gamedata.", sBuffer);

    // Unlock Max SI limit - 这是唯一需要保留的 gamedata patch
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

    // 如果是特感 bot
    if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == 3 && IsFakeClient(client))
    {
        // 标记为即将踢出，防止被 GetTotalSI_Strict 误判（虽然 IsPlayerAlive 已经防住了）
        // 0.1秒后踢出，给死亡动画一点面子，如果追求极致可以设为 0.0
        CreateTimer(0.1, Timer_KickDeadBot, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Continue;
}

public Action Timer_KickDeadBot(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && !IsPlayerAlive(client))
    {
        KickClient(client, "Instant Cleanup");    // 立即释放槽位
    }
    return Plugin_Stop;
}

// =========================================================================
// 插件主逻辑
// =========================================================================
public void OnPluginStart()
{
    bNavCacheEnable = true;
    g_hSpawnQueue   = new ArrayList();
    InitSDK_FromGamedata();    // ← 加载 NavArea SDK/偏移
    // [Nav] 初始化空桶
    for (int i = 0; i < FLOW_BUCKETS; i++)
        g_FlowBuckets[i] = null;    // 先置空，在 Build 时创建

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
    //  注册常驻倒霉蛋开关 (默认为 1: 开启)
    g_cvGriefPermanentEnv  = CreateConVar("sd_grief_permanent", "0", "是否启用代码中写死的常驻倒霉蛋功能 (1=开启, 0=关闭)");
    g_cvPhantomMaxSounds   = CreateConVar("sd_phantom_max_sounds", "4", "触发幻听时，最多同时播放几条进攻声音 (建议 2-4)");

    g_cvDifficultyTier     = CreateConVar("sd_difficulty_tier", "2", "难度档位(1-6): 1=无尸潮, 2=标准, 3=进阶, 4=长尸潮, 5=地狱(克存活高压), 6=绝境(继承5档+特感无声+终点暴走)");
    g_cvPhantomIntervalMin = CreateConVar("sd_phantom_interval_min", "4.0", "随机幻听的最小触发间隔 (秒)");
    g_cvPhantomIntervalMax = CreateConVar("sd_phantom_interval_max", "15.0", "随机幻听的最大触发间隔 (秒)");
    g_cvDifficultyTier.AddChangeHook(OnTierVarChanged);    // 监听修改

    AddNormalSoundHook(Hook_NormalSound);

    VsBossFlowBuffer = FindConVar("versus_boss_buffer");
    if (VsBossFlowBuffer != null)
    {
        VsBossFlowBuffer.AddChangeHook(OnFlowBufferChanged);
    }
    // 初始化恶搞名单
    g_hGriefTargets = new ArrayList(ByteCountToCells(64));    // 存字符串需要转换大小
    BuildPath(Path_SM, g_sGriefFilePath, sizeof(g_sGriefFilePath), "data/sd_grief_targets.txt");
    LoadGriefTargets();    // 开局读取

    // 注册命令 (只有 ROOT 权限可用)
    RegAdminCmd("sm_sd_grief", Cmd_ToggleGrief, ADMFLAG_ROOT, "开关指定玩家的贴脸刷怪模式");
    // [Nav管理] 3. 注册命令 (用于调试)
    RegAdminCmd("sm_sd_rebuild_nav", Cmd_RebuildNav, ADMFLAG_ROOT, "强制重建Nav分桶");
    RegAdminCmd("sm_nd_flow", Cmd_NavDebugFlow, ADMFLAG_ROOT, "可视化 Nav 分桶流向 (画出通往终点的 Flow 路径)");
    // 在 OnPluginStart() 里添加这一行
    RegAdminCmd("sm_nd", Cmd_NavDebug, ADMFLAG_ROOT, "调试当前位置的Nav和分桶信息");

    //    AutoExecConfig(true, "smart_director_v22_clean");

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
    // HookEvent("player_spawn", Event_PlayerSpawn_Account);
    HookEvent("player_death", Event_PlayerDeath_Kick, EventHookMode_Pre);    // 用 Pre 更快地检测到死亡，及时销账

    HookEvent("player_team", Event_CacheUpdate);
    HookEvent("player_spawn", Event_CacheUpdate_Spawn);
    HookEvent("player_death", Event_CacheUpdate);
    HookEvent("player_disconnect", Event_CacheUpdate_Disconnect);

    RegAdminCmd("sm_sd_force_spawn", Cmd_ForceSpawn, ADMFLAG_ROOT, "强制生成");
    RegAdminCmd("sm_sd_force_tank", Cmd_ForceTank, ADMFLAG_ROOT, "强制Tank封路测试");
    RegAdminCmd("sm_sd_rebuild_nav", Cmd_RebuildNav, ADMFLAG_ROOT, "强制重建Nav分桶");

    PrecacheSound("player/hunter/voice/attack/hunter_shriek_1.wav");       // Hunter 飞扑尖叫
    PrecacheSound("player/boomer/voice/attack/boomer_attack_01.wav");      // Boomer 吐胆汁的瞬间
    PrecacheSound("player/smoker/voice/attack/smoker_attack_01.wav");      // Smoker 吐舌头
    PrecacheSound("player/jockey/voice/attack/jockey_attack_01.wav");      // Jockey 起跳怪叫
    PrecacheSound("player/charger/voice/attack/charger_charge_01.wav");    // Charger 冲锋怒吼

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

// public Action Event_PlayerSpawn_Account(Event event, const char[] name, bool dontBroadcast)
// {
//     int client = GetClientOfUserId(event.GetInt("userid"));
//     if (client > 0 && IsFakeClient(client) && GetClientTeam(client) == 3)
//     {
//         // 怪生出来了！销账！
//         if (g_iTotalPending > 0)
//         {
//             g_iTotalPending--;
//         }

//         g_fSpawnTime[client] = GetEngineTime();

//         // 双重保险：防止长时间没生出来导致 g_iTotalPending 卡在非0
//         // 可以加个 5秒 的 Timer 强制归零 g_iTotalPending，或者定期校准
//     }
//     return Plugin_Continue;
// }
public void OnPluginEnd()
{
    LockLimits();
    delete g_hSpawnQueue;
    ClearNavAreasCache();
}

public Action Event_PanicEvent(Event event, const char[] name, bool dontBroadcast)
{
    // 1. 记录原始距离（如果是第一次触发，防止重复覆盖）
    if (!g_bPanicMode)
    {
        g_fOriginalMinDist = g_cvSpawnDistMin.FloatValue;
        g_fOriginalMaxDist = g_cvSpawnDistMax.FloatValue;
    }
    // 2. 激活高压模式
    g_bPanicMode = true;

    // 3. 压缩生成距离 (让特感贴脸刷，比如 100~500)
    // 这样能模拟“四面楚歌”的感觉，因为守点时玩家通常不动，远处的怪没有威胁
    g_cvSpawnDistMin.SetFloat(100.0);
    g_cvSpawnDistMax.SetFloat(600.0);
    UnlockLimits();    // 应用到引擎

    PrintToChatAll("\x04[Sion]\x01 : \x03尸潮爆发！\x01特感距离已压缩，AOE配额提升！");

    // 4. 设置复位定时器
    // 尸潮持续时间通常是未知的，我们可以设定一个保守值（如 45秒），或者监听尸潮结束事件
    if (g_hPanicEndTimer != null) KillTimer(g_hPanicEndTimer);
    g_hPanicEndTimer = CreateTimer(10.0, Timer_EndPanicMode);

    return Plugin_Continue;
}

// 尸潮结束/复位逻辑
public Action Timer_EndPanicMode(Handle timer)
{
    g_bPanicMode     = false;
    g_hPanicEndTimer = null;

    // 还原距离
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
    // [Fix] Removed g_iLaserSprite (Warning Fix)
}

public void OnMapEnd()
{
    ClearNavBuckets();
    // 2. 清理基础 Nav 缓存 (NavAreas)
    ClearNavAreasCache();
}
// ✅ 新增：清理缓存
stock void ClearNavAreasCache()
{
    if (g_AllNavAreasCache != null)
    {
        delete g_AllNavAreasCache;
        g_AllNavAreasCache   = null;
        g_NavAreasCacheCount = 0;
        // Debug_Print("[NAV CACHE] Cleared");
    }
}

public Action Cmd_RebuildNav(int client, int args)
{
    RebuildNavBuckets();    // 调用你复制进去的重建函数
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

    // 模式 1: 仅检查特定目标
    if (mode == 1 && IsValidClient(target))
    {
        if (L4D2_IsVisibleToPlayer(target, TEAM_SURVIVOR, TEAM_INFECTED, 0, checkPos)) return true;
        return false;
    }

    // 模式 2: 循环检查全队 (极速版)
    for (int i = 1; i <= MaxClients; i++)
    {
        // [优化] 这里用了宏，直接检查位，不调用 API
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

    // 计算“有效射线模式”
    // 0 = 仅中线；1 = 三线；2 = 自动（>4生还者→仅中线，否则三线）
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

        // 先试“中线 → 头”
        if (effMode != 1 && RayClear(eyes, head, visMask))
            return true;

        // 若模式要求三线，再做左右偏移
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

        // 引擎可视（到胸）兜底
        if (L4D2_IsVisibleToPlayer(i, TEAM_SURVIVOR, TEAM_INFECTED, 0, chest))
            return true;
    }

    return false;
}
// bool SD_FindNavSpawnPos_Advanced(int targetClient, float minRange, float maxRange, bool reqVis, float outPos[3])
// {
//     if (!g_BucketsReady) return false;

//     float targetPos[3];
//     GetClientAbsOrigin(targetClient, targetPos);

//     int targetPercent = 0;
//     // 1. 使用安全的获取方式纠正断层进度
//     if (!TryGetClientFlowPercentSafe(targetClient, targetPercent)) {
//         // 2. 如果彻底断层，使用回退进度兜底
//         int fpct;
//         if (GetFallbackSurPct(fpct)) {
//             targetPercent = fpct;
//         }
//     }

//     int searchBuckets[FLOW_BUCKETS];
//     int bucketCount = 0;

//     // =================================================================
//     // [核心清理] 彻底干掉 isPathBlocked 逻辑！
//     // 直接使用 BuildBucketOrder，以当前进度为中心，前后铺开搜索 (范围25个桶)
//     // 这样无论是什么地形，特感都会在前后方随机包抄
//     // =================================================================
//     bucketCount = BuildBucketOrder(targetPercent, 25, true, searchBuckets);

//     for (int i = 0; i < bucketCount; i++)
//     {
//         int b = searchBuckets[i];
//         if (g_BucketMaxZ[b] < targetPos[2] - 500.0 || g_BucketMinZ[b] > targetPos[2] + 500.0)
//             continue;

//         ArrayList bucket = g_FlowBuckets[b];
//         if (bucket == null || bucket.Length == 0) continue;

//         int count    = bucket.Length;
//         int attempts = (count > 8) ? 8 : count;

//         for (int k = 0; k < attempts; k++)
//         {
//             int     areaIdx  = bucket.Get(GetRandomInt(0, count - 1));
//             Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
//             if (areaAddr == Address_Null) continue;

//             NavArea pArea = view_as<NavArea>(areaAddr);
//             float   p[3];
//             pArea.GetRandomPoint(p);

//             float dist  = GetVectorDistance(targetPos, p);
//             float slack = (p[2] > targetPos[2] + 100.0) ? 150.0 : 0.0;

//             // [修复编译错误] 既然没有阻塞状态了，直接使用传进来的 minRange
//             if (dist < minRange || dist > (maxRange + slack)) continue;

//             if (WillStuck(p)) continue;
//             if (reqVis && SD_IsPosVisible(p, targetClient)) continue;

//             // 动态计算寻路极限：直线距离的 1.5 倍 + Z轴高度差的 2.5 倍（补偿走楼梯绕路）
//             float zDiff = FloatAbs(p[2] - targetPos[2]);
//             float pathLimit = (dist * 1.5) + (zDiff * 2.5);

//             // 调用修复后的寻路函数
//             if (PathPenalty_NoBuild(p, targetClient, pathLimit) != 0.0)
//                 continue;

//             outPos = p;
//             return true;
//         }
//     }

//     return false;
// }
bool SD_FindNavSpawnPos_Advanced(int targetClient, float minRange, float maxRange, bool reqVis, float outPos[3])
{
    if (!g_BucketsReady) return false;
    float targetPos[3];
    GetClientAbsOrigin(targetClient, targetPos);

    int targetPercent = 0;
    // 1. 使用安全的获取方式纠正断层进度
    if (!TryGetClientFlowPercentSafe(targetClient, targetPercent))
    {
        // 2. 如果彻底断层，使用回退进度兜底
        int fpct;
        if (GetFallbackSurPct(fpct))
        {
            targetPercent = fpct;
        }
    }

    int searchBuckets[FLOW_BUCKETS];
    int bucketCount = 0;

    // 直接使用 BuildBucketOrder，以当前进度为中心，前后铺开搜索 (范围25个桶)
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

            // =================================================================
            // [新增] 强制立体包围 (反扎堆检测)
            // =================================================================
            if (!PassMinSeparation(p)) continue;

            // 动态计算寻路极限：直线距离的 1.5 倍 + Z轴高度差的 2.5 倍
            float zDiff     = FloatAbs(p[2] - targetPos[2]);
            float pathLimit = (dist * 1.5) + (zDiff * 2.5);

            // 调用修复后的寻路函数
            if (PathPenalty_NoBuild(p, targetClient, pathLimit) != 0.0)
                continue;

            outPos = p;

            // =================================================================
            // [新增] 记录成功点位，供同批次的下一个特感避开此区域
            // =================================================================
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
// bool SD_FindNavSpawnPos_Advanced(int targetClient, float minRange, float maxRange, bool reqVis, float outPos[3])
// {
//     if (!g_BucketsReady) return false;

//     float targetPos[3];
//     GetClientAbsOrigin(targetClient, targetPos);

//     // === 修复为 ===
//     int targetPercent = 0;
//     // 1. 使用你自己的安全函数，它会自动通过脚底区域去纠正断层进度
//     if (!TryGetClientFlowPercentSafe(targetClient, targetPercent)) {
//         // 2. 如果彻底断层，使用你的回退进度兜底，防止归零
//         int fpct;
//         if (GetFallbackSurPct(fpct)) {
//             targetPercent = fpct;
//         }
//     }

//     // bool isPathBlocked = SD_IsForwardBlockedForSurvivors(targetClient);
//     int  searchBuckets[FLOW_BUCKETS];
//     int  bucketCount = 0;

//     searchBuckets[bucketCount++] = targetPercent;
//     for (int i = 1; i <= 10; i++)
//     {
//         int b = targetPercent - i;
//         if (b >= 0) searchBuckets[bucketCount++] = b;
//     }

//     // if (isPathBlocked)
//     // {
//     //     searchBuckets[bucketCount++] = targetPercent;
//     //     for (int i = 1; i <= 10; i++)
//     //     {
//     //         int b = targetPercent - i;
//     //         if (b >= 0) searchBuckets[bucketCount++] = b;
//     //     }
//     // }
//     // else
//     // {
//     //     bucketCount = BuildBucketOrder(targetPercent, 25, true, searchBuckets);
//     // }

//     for (int i = 0; i < bucketCount; i++)
//     {
//         int b = searchBuckets[i];
//         if (g_BucketMaxZ[b] < targetPos[2] - 500.0 || g_BucketMinZ[b] > targetPos[2] + 500.0)
//             continue;

//         ArrayList bucket = g_FlowBuckets[b];
//         if (bucket == null || bucket.Length == 0) continue;

//         int count    = bucket.Length;
//         int attempts = (count > 8) ? 8 : count;

//         for (int k = 0; k < attempts; k++)
//         {
//             int     areaIdx  = bucket.Get(GetRandomInt(0, count - 1));
//             Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
//             if (areaAddr == Address_Null) continue;

//             NavArea pArea = view_as<NavArea>(areaAddr);
//             float   p[3];
//             pArea.GetRandomPoint(p);

//             float dist         = GetVectorDistance(targetPos, p);
//             // float realMinRange = isPathBlocked ? (minRange * 0.7) : minRange;
//             float slack        = (p[2] > targetPos[2] + 100.0) ? 150.0 : 0.0;

//             if (dist < realMinRange || dist > (maxRange + slack)) continue;
//             if (WillStuck(p)) continue;
//             if (reqVis && SD_IsPosVisible(p, targetClient)) continue;

//             // [核心修复] 动态计算寻路极限：直线距离的 1.5 倍 + Z轴高度差的 2.5 倍（补偿走楼梯绕路）
//             float zDiff = FloatAbs(p[2] - targetPos[2]);
//             float pathLimit = (dist * 1.5) + (zDiff * 2.5);

//             // 调用修复后的寻路函数
//             if (PathPenalty_NoBuild(p, targetClient, pathLimit) != 0.0)
//                 continue;

//             outPos = p;
//             return true;
//         }
//     }
//     return false;
// }
// bool SD_FindNavSpawnPos_Advanced(int targetClient, float minRange, float maxRange, bool reqVis, float outPos[3])
// {
//     if (!g_BucketsReady) return false;

//     // 1. 准备数据
//     float targetPos[3];
//     GetClientAbsOrigin(targetClient, targetPos);

//     float targetFlow    = L4D2Direct_GetFlowDistance(targetClient);

//     // 计算百分比
//     int   targetPercent = 0;
//     if (g_fMapMaxFlow > 1.0)
//         targetPercent = RoundToNearest((targetFlow / g_fMapMaxFlow) * 100.0);
//     targetPercent      = clampi(targetPercent, 0, 100);

//     // =================================================================
//     // [战术决策] 核心改动点
//     // =================================================================
//     // 使用探针检测：前面的门/路是不是断的？
//     bool isPathBlocked = SD_IsForwardBlockedForSurvivors(targetClient);

//     int  searchBuckets[FLOW_BUCKETS];
//     int  bucketCount = 0;

//     if (isPathBlocked)
//     {
//         // >>> 模式 A：关门打狗 (只刷身后) <<<
//         // 既然前面不通，我们就死心塌地只刷“当前”和“后面”
//         // 这样怪就会刷在生还者身边的树林里，或者屁股后面

//         // 1. 加入当前桶 (脚下/旁边)
//         searchBuckets[bucketCount++] = targetPercent;

//         // 2. 加入后方桶 (往回搜 15% 的路程)
//         // 这样特感会从后面包抄，或者从旁边的树林出来
//         for (int i = 0; i <= 10; i++)
//         {
//             int b = targetPercent - i;
//             if (b >= 0) searchBuckets[bucketCount++] = b;
//         }

//         // 注意：这里绝对没有加入 targetPercent + 1 (前方桶)
//         // 所以根本不需要 hardFlowLimit，因为算法根本不会去看门后的点
//     }
//     else
//     {
//         // >>> 模式 B：全速推进 (刷前方) <<<
//         // 门开了，或者根本没门。
//         // 使用 BuildBucketOrder (前2后1) 进行广域搜索，默认偏向前方
//         bucketCount = BuildBucketOrder(targetPercent, 25, true, searchBuckets);
//     }

//     // 3. 开始极速遍历
//     for (int i = 0; i < bucketCount; i++)
//     {
//         int b = searchBuckets[i];

//         // [优化] 桶级高度粗筛
//         if (g_BucketMaxZ[b] < targetPos[2] - 500.0 || g_BucketMinZ[b] > targetPos[2] + 500.0)
//             continue;

//         ArrayList bucket = g_FlowBuckets[b];
//         if (bucket == null || bucket.Length == 0) continue;

//         // [抽样]
//         int count    = bucket.Length;
//         int attempts = (count > 8) ? 8 : count;

//         for (int k = 0; k < attempts; k++)
//         {
//             // 随机取点
//             int     areaIdx  = bucket.Get(GetRandomInt(0, count - 1));
//             Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
//             if (areaAddr == Address_Null) continue;

//             NavArea pArea = view_as<NavArea>(areaAddr);

//             // [逻辑简化] 不需要 hardFlowLimit 检查了
//             // 因为如果是关门状态，searchBuckets 里根本就没有门后的桶

//             // [属性检查] 避开安全屋等

//             float   p[3];
//             pArea.GetRandomPoint(p);

//             // [距离检查]
//             float dist         = GetVectorDistance(targetPos, p);

//             // 守点模式下(PathBlocked)，允许怪刷得更近一点，增加压迫感
//             float realMinRange = isPathBlocked ? (minRange * 0.7) : minRange;

//             float slack        = (p[2] > targetPos[2] + 100.0) ? 150.0 : 0.0;

//             if (dist < realMinRange || dist > (maxRange + slack)) continue;

//             // [防卡检查]
//             if (WillStuck(p)) continue;

//             // [可视检查]
//             // if (IsPosVisibleSDK(p, targetClient)) continue;
//             if (reqVis && SD_IsPosVisible(p, targetClient)) continue;

//             // [路径检查]
//             // 这一点非常重要：即使我们只在身后刷，也要保证特感能跑过来
//             // (比如防止刷在身后的封闭房间里)
//             float pathLimit = dist * 1.3;

//             if (PathPenalty_NoBuild(p, targetClient, float(b - targetPercent), pathLimit) != 0.0)
//                 continue;

//             // [成功] 找到点，立即返回
//             outPos = p;
//             return true;
//         }
//     }

//     // 搜遍了也没找到
//     return false;
// }

// [修改] —— 距离平滑评分：以“甜点距离 sweet”为中心的对称衰减
stock float ScoreDistSmooth(float dminEye, float sweet, float width)
{
    // 防御：宽度太小会过于尖锐
    if (width < 1.0) width = 1.0;

    // 归一化偏差
    float t = FloatAbs(dminEye - sweet) / width;

    // 100 / (1 + e^(k*t))，t 越大衰减越多；k 适中给点锐度
    float k = 1.5;
    float s = 100.0 / (1.0 + ExpF(k * t));

    // 限幅，避免因为极端参数出 0 分或 100+ 分
    return clamp(s, 10.0, 100.0);
}
#define M_E 2.718281828459045
stock float ExpF(float x)
{
    return Pow(M_E, x);
}
// [新增] 新评分系统 - 计算高度得分 (可为负)
// [ADD] New Scoring System - Calculate Height Score (can be negative)
stock float CalculateScore_Height(int zc, const float p[3], float refEyeZ)
{
    float zRel = p[2] - refEyeZ;

    // --- 平面型特感 (Charger / Jockey) ---
    if (zc == view_as<int>(SI_Charger) || zc == view_as<int>(SI_Jockey))
    {
        const float CJ_ALLOWED_PLANE = 150.0;
        float       distPlane        = FloatAbs(zRel);
        if (distPlane <= CJ_ALLOWED_PLANE)
        {
            return 90.0 - (distPlane / CJ_ALLOWED_PLANE) * 20.0;    // 在平面内，分数 70-90
        }
        else
        {
            return 60.0 - (distPlane - CJ_ALLOWED_PLANE) * 0.2;    // 偏离平面则分数骤减
        }
    }

    // --- 垂直/通用型特感 ---
    float       score              = 0.0;
    const float HEIGHT_PEAK_WINDOW = 400.0;
    const float TAPER_BASE_DIST    = 250.0;

    if (zRel <= 20.0)    // 在下方或略高，不加分
    {
        score = 0.0;
    }
    else if (zRel <= HEIGHT_PEAK_WINDOW)    // 在理想高度区间内，线性加分
    {
        score = (zRel / HEIGHT_PEAK_WINDOW) * 100.0;
    }
    else    // 超出理想高度，分数衰减
    {
        float over  = zRel - HEIGHT_PEAK_WINDOW;
        float taper = 1.0 / (1.0 + (over / TAPER_BASE_DIST));
        score       = 100.0 * taper;
    }

    // 空降潜力加分
    float land[3];
    if (FindDropLanding(p, land))
    {
        float d = GetMinDistToAnySurvivor(land);
        if (d < 450.0) score += 40.0 * (1.0 - d / 450.0);    // 离落点越近，加分越多
    }

    return score;
}
static bool FindDropLanding(const float from[3], float outLand[3], float maxDrop = 480.0)
{
    float start[3];
    start[0] = from[0];
    start[1] = from[1];
    start[2] = from[2] + 1.0;

    float end[3];
    end[0]    = from[0];
    end[1]    = from[1];
    end[2]    = from[2] - maxDrop;

    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter);
    if (!TR_DidHit(tr))
    {
        delete tr;
        return false;
    }

    TR_GetEndPosition(outLand, tr);
    delete tr;

    Address nav = L4D_GetNearestNavArea(outLand, 120.0, false, false, false, TEAM_INFECTED);
    return nav != Address_Null;
}
static float GetMinDistToAnySurvivor(const float p[3])
{
    float best = 999999.0;
    float s[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvFast(i)) continue;
        GetClientAbsOrigin(i, s);
        float d = GetVectorDistance(p, s);
        if (d < best) best = d;
    }
    return best;
}
// [新增] —— 简单读写（无 TTL）
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
// [核心修复] 直接接收计算好的寻路极限距离 limitCost
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

    // [修复] 不再瞎算 limitCost，直接使用传进来的参数
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
// [修改] —— 整函数覆盖：使用波级缓存（无 TTL）
// stock float PathPenalty_NoBuild(const float candPos[3], int targetSur, float ring, float spawnmax)
// {
//     // 选目标幸存者：优先 targetSur，其次任意存活
//     int surv = -1;
//     if (IsValidSurvFast(targetSur) && IsAlive(targetSur) && !L4D_IsPlayerIncapacitated(targetSur))
//     {
//         surv = targetSur;
//     }
//     else
//     {
//         for (int i = 1; i <= MaxClients; i++)
//         {
//             if (IsValidSurvFast(i) && IsAlive(i) && !L4D_IsPlayerIncapacitated(i))
//             {
//                 surv = i;
//                 break;
//             }
//         }
//     }
//     if (surv == -1) return PATH_NO_BUILD_PENALTY;    // 没有可用幸存者，按“不可达”

//     // 生还者位置（与你 SpawnInfected 的口径一致）
//     float survPos[3];
//     GetClientEyePosition(surv, survPos);
//     survPos[2] -= 60.0;

//     // 找最近 NavArea
//     Address navGoal  = L4D_GetNearestNavArea(candPos, 120.0, false, false, false, TEAM_INFECTED);
//     Address navStart = L4D_GetNearestNavArea(survPos, 120.0, false, false, false, TEAM_INFECTED);
//     if (!navGoal || !navStart) return PATH_NO_BUILD_PENALTY;

//     // 代价上限：min(ring*3, spawnmax*1.5)
//     float limitCost = FloatMin(ring * 3.0, spawnmax * 1.5);

//     if (bPathCacheEnable)
//     {
//         char key[64];
//         PathCache_BuildKey(navGoal, navStart, limitCost, key, sizeof key);

//         bool okCached;
//         if (PathCache_TryGetSimple(key, okCached))
//             return okCached ? 0.0 : PATH_NO_BUILD_PENALTY;

//         bool ok = L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false);
//         PathCache_PutSimple(key, ok);
//         return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
//     }

//     // 不启用缓存：直接判定
//     bool ok = L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false);
//     return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
// }

// [MOD] —— 覆盖：无重叠、可读的 Flow 评分
// 语义：略微领先（+1..+5）最好；过远前方衰减；同进度中性；落后扣分。
stock float ScoreFlowSmooth(int deltaFlow)
{
    // 后方：-12 以下直接给极低
    if (deltaFlow <= -12) return 0.0;

    // 后方：-11..-1 线性爬升到 30 分（仍然是偏低，鼓励前置）
    if (deltaFlow < 0)
    {
        // -11 -> 5 分,  -1 -> 30 分
        float t = float(deltaFlow + 11) / 10.0;    // 0..1
        return 5.0 + t * 25.0;                     // 5..30
    }

    // 同进度：给中性 50 分
    if (deltaFlow == 0) return 50.0;

    // 前方近距离最佳：+1..+5 → 100 分
    if (deltaFlow <= 5) return 100.0;

    // 前方中距离：+6..+12 从 85 线性降到 45
    if (deltaFlow <= 12)
    {
        float t = float(deltaFlow - 6) / 6.0;    // 0..1
        return 85.0 - t * 40.0;                  // 85..45
    }

    // 前方太远（>+12）：缓慢衰减到 30~40 的平台
    // 用个平滑函数避免突变
    float over = float(deltaFlow - 12);
    float s    = 40.0 / (1.0 + (over / 8.0));    // 40 → 渐近 0
    return 30.0 + clamp(s, 0.0, 40.0);           // 30..70（但很快收敛到 30~40）
}
// [修改] 解决 warning 219: local variable "recentSectors" shadows a variable
stock float CalculateScore_Dispersion(int sidx, int preferredSector, const int a_recentSectors[3])
{
    float k = PenLimitScale();                           // 1.00..0.50
    if (sidx == preferredSector) return 100.0;           // 正向奖励不缩
    if (sidx == a_recentSectors[0]) return -50.0 * k;    // 最近扇区的负分随上限减半
    if (sidx == a_recentSectors[1]) return -25.0 * k;    // 次近扇区同理
    if (sidx == a_recentSectors[2]) return 0.0;
    return 50.0;
}
// [ADD] 负向分散度惩罚随上限 L 变弱（用你给的宏）
stock float ComputePenScaleByLimit(int L)
{
    int   Lc = clampi(L, PEN_LIMIT_MINL, PEN_LIMIT_MAXL);
    float t  = float(Lc - PEN_LIMIT_MINL) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL);    // 0..1
    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}
stock float ScaleNegativeOnly(float v, float k) { return (v < 0.0) ? (v * k) : v; }
// [新增] —— 生成缓存 Key（NavAreaID + 量化后的 limitCost）
stock void  PathCache_BuildKey(Address navGoal, Address navStart, float limitCost, char[] outKey, int maxlen)
{
    int idG = (navGoal != Address_Null) ? L4D_GetNavAreaID(navGoal) : -1;
    int idS = (navStart != Address_Null) ? L4D_GetNavAreaID(navStart) : -1;
    int q   = RoundToNearest(limitCost / fPathCacheQuantize);    // 量化，避免 key 激增
    Format(outKey, maxlen, "%d|%d|%d", idG, idS, q);
}
// =========================================================================
// 环境 & 限制
// =========================================================================

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
    // 1. 读取当前的 sd_max_si 值
    // 无论是 CFG 加载的，还是你控制台手输入的，还是 API 改的，都以这个为准
    int limit = g_cvMaxSI.IntValue;

    // 2. 基础安全范围 (防止设成 0 卡死或者设成 100 崩服)
    if (limit < 4) limit = 4;
    if (limit > 32) limit = 32;

    ConVar cvar;

    // 3. 设置引擎总上限 (同步 sd_max_si 的值)
    if ((cvar = FindConVar("z_max_player_zombies")) != null)
    {
        cvar.SetBounds(ConVarBound_Upper, true, 32.0);
        cvar.SetInt(limit);
    }
    if ((cvar = FindConVar("z_minion_limit")) != null) cvar.SetInt(limit);
    if ((cvar = FindConVar("survival_max_specials")) != null) cvar.SetInt(limit);

    // 4. [关键] 单类特感上限
    // 逻辑：如果是超级模式，所有单类上限直接解锁到总上限 (limit)，由代码比例控制。
    // 如果是普通模式，维持原版平衡 (牛=4, 胖=2)，或者你也可以选择全部放开让 sd_max_si 控制。
    // 这里我保持你想要的“超级模式下才解锁”的逻辑：

    int typeLimit   = g_bSuperMode ? limit : 4;
    int boomerLimit = g_bSuperMode ? limit : 2;

    if ((cvar = FindConVar("z_smoker_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_boomer_limit")) != null) cvar.SetInt(boomerLimit);
    if ((cvar = FindConVar("z_hunter_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_spitter_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_jockey_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_charger_limit")) != null) cvar.SetInt(typeLimit);

    // 5. [修正] 距离参数 - 不再暴力覆盖！
    // 只有当这些参数真的不合理时（比如小于你设定的最小生成距离），才去修正它。
    // 现在的逻辑：将引擎的生成范围设得比你插件的 sd_dist_max 稍微大一点，给插件留出操作空间。

    float myMaxDist   = g_cvSpawnDistMax.FloatValue;
    // 引擎的 z_spawn_range 必须大于插件的 max，否则引擎会强行杀掉刷出来的怪
    int   engineRange = RoundToCeil(myMaxDist + 500.0);
    if (engineRange < 2000) engineRange = 2000;    // 兜底

    if ((cvar = FindConVar("z_spawn_range")) != null) cvar.SetInt(engineRange);

    // 自动清理距离：设得比生成距离远 1000 码，防止刚刷出来就被清理
    if ((cvar = FindConVar("z_discard_range")) != null) cvar.SetInt(engineRange + 1000);

    // 允许贴脸生成 (由插件代码控制可见性，引擎层放开)
    if ((cvar = FindConVar("z_safe_spawn_range")) != null) cvar.SetInt(0);

    // 6. 更新内部配额
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

// 安全区与队列
// public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
// {
//     if (g_bLeftSafeArea) return;
//     g_bLeftSafeArea = true;

//     // 1. 解锁限制
//     UnlockLimits();

//     int   maxSI    = g_cvMaxSI.IntValue;
//     float interval = g_cvHungerCooldown.FloatValue;
//     float distMin  = g_cvSpawnDistMin.FloatValue;
//     float distMax  = g_cvSpawnDistMax.FloatValue;

//     // \x04 = 橙色/绿色(视服务器而定), \x01 = 白色, \x03 = 亮绿色
//     PrintToChatAll("\x04[Sion]\x01 生还者离开安全区。");
//     PrintToChatAll("\x04[配置]\x01 特感上限: \x03%d \x01只 | 刷新间隔: \x03%.1f \x01秒", maxSI, interval);
//     PrintToChatAll("\x04[参数]\x01 生成距离: \x03%.0f \x01- \x03%.0f", distMin, distMax);

//     // 3. 清理旧计时器 (保持不变)
//     if (g_hSpawnTimer != null)
//     {
//         KillTimer(g_hSpawnTimer);
//         g_hSpawnTimer = null;
//     }
//     if (g_hCacheTimer != null)
//     {
//         KillTimer(g_hCacheTimer);
//         g_hCacheTimer = null;
//     }
//     if (g_hQueueTimer != null)
//     {
//         KillTimer(g_hQueueTimer);
//         g_hQueueTimer = null;
//     }

//     // 4. 启动逻辑 (保持不变)
//     g_hCacheTimer = CreateTimer(0.2, Timer_UpdateDeltaCache, _, TIMER_REPEAT);
//     SD_FullStateRefresh();

//     // 10秒后才开始正式刷怪逻辑
//     CreateTimer(10.0, Timer_StartCombatDelayed, _, TIMER_FLAG_NO_MAPCHANGE);
// }
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

    // [难度系统] 出门播报
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

public Action Timer_ProcessQueue(Handle timer)
{
    if (!g_bLeftSafeArea || g_hSpawnQueue.Length == 0) return Plugin_Continue;

    // 2. 爆发循环：只要队列有货，就一直刷
    while (g_hSpawnQueue.Length > 0)
    {
        // 取出任务
        int class = g_hSpawnQueue.Get(0);
        g_hSpawnQueue.Erase(0);

        // --- 记账开始 ---
        // 告诉导演：这只怪已经下单了，虽然还没生出来，但别再补货了！
        g_iTotalPending++;
        // ----------------

        // 尝试寻找位置
        int target = SD_GetBestStrategicTarget();
        if (target <= 0) target = SD_GetRandomSurvivor();

        bool spawned = false;
        if (target > 0)
        {
            // 发出生成指令 (你的生成函数)
            spawned = SD_SpawnWithNavBucket(class, target);
        }

        // 如果连指令都发不出去（比如找不到位置），要把账撤销
        if (!spawned)
        {
            g_iTotalPending--;
            // 可选：把失败的任务塞回队尾重试，或者直接丢弃
            // g_hSpawnQueue.Push(class);
        }
    }
    return Plugin_Continue;
}

// public Action Timer_ProcessQueue(Handle timer)
// {
//     if (!g_bLeftSafeArea) return Plugin_Continue;
//     if (g_hSpawnQueue.Length == 0) return Plugin_Continue;

//     // [核心修改] 爆发式生成 (Explosive Spawn)
//     // 我们不再限制 batchSize 为 1 个或 2 个，而是尽可能在一个 tick 内把整队刷出来。
//     // 为了防止服务器卡顿，我们设一个较高的硬上限 (比如 16)，这对于玩家来说就是"瞬间"。

//     int burstLimit = g_cvMaxSI.IntValue;    // 这个上限可以根据 sd_max_si 调整，保持一致性
//     int processed  = 0;
//     int target     = g_iCachedBestTarget;

//     // 如果缓存的目标失效了（极其罕见，比如这0.1秒内掉线），才重新算
//     if (target <= 0 || !IsClientInGame(target)) target = SD_GetBestStrategicTarget();
//     if (target <= 0) target = SD_GetRandomSurvivor();

//     // 只要队列还有怪，且没达到防卡顿上限，就一直刷
//     while (g_hSpawnQueue.Length > 0 && processed < burstLimit)
//     {
//         if (SD_GetSICount() >= g_cvMaxSI.IntValue)
//         {
//             // 甚至可以直接清空队列，防止堆积
//             g_hSpawnQueue.Clear();
//             // return Plugin_Continue;
//             return Plugin_Continue;
//         }
//         // 1. 取出特感类型
//         int class = g_hSpawnQueue.Get(0);
//         g_hSpawnQueue.Erase(0);
//         // 2. 锁定目标
//         // 既然是爆发，我们需要针对性。
//         // 如果是控制特感，优先找落单的或者 Leader；如果是 AOE，优先找人堆。
//         // 这里为了简化且有效，统一使用"最佳战术目标"
//         if (target > 0)
//         {
//             // 3. 尝试生成
//             // 使用我们优化过的环形搜索，确保位置合理
//             bool success = SD_SpawnWithNavBucket(class, target);

//             if (success)
//             {
//                 processed++;
//             }
//             else {
//                 // 如果生成失败 (比如位置不好)，为了保证波次完整性，
//                 // 我们应该把它放回队列头部，等待下一帧（0.1秒后）立刻重试
//                 // 但为了防止死循环，我们把它放到队尾
//                 // g_hSpawnQueue.Push(class); // (可选：如果觉得卡顿可以注释掉这行，失败就失败了)

//                 // 为了保持高压，建议失败了就丢弃，不要阻塞队列，反正下一波马上就来
//                 // 或者：把它转变为 Hunter (容错率高) 塞回去?
//                 // 这里选择：不做任何事，跳过。保证流畅度。
//             }
//         }
//     }

//     return Plugin_Continue;
// }

// 2. 纯随机 (无脑选一个活着的，作为最后的兜底)
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

// 事件 & 缓存
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
    // [新增] 终点绝杀拌线触发标记
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

// public Action Timer_DirectorThink(Handle timer)
// {
//     if (!g_bLeftSafeArea) return Plugin_Continue;
//     if (!SD_IsSurvivorTeamAlive()) return Plugin_Continue;

//     SD_CullLaggingSI_Fast();
//     float time = GetEngineTime();

//     // 1. Tank 逻辑 (保持不变)
//     if (g_cvEnableTankControl.BoolValue)
//     {
//         if (!g_bTankSpawnedRound && time > g_fNextTankTime && !SD_IsTankAlive())
//         {
//             if (GetRandomInt(1, 100) <= g_cvTankChance.IntValue)
//             {
//                 int target = SD_GetBestStrategicTarget();
//                 if (target > 0) SD_AttemptTankAssault(target);
//             }
//         }
//     }

//     // =========================================================
//     // [核心修改] 波次刷新逻辑 (Wave Spawn)
//     // =========================================================

//     // 检查冷却
//     if ((time - g_fLastSupplyTime) < g_cvHungerCooldown.FloatValue)
//     {
//         return Plugin_Continue;
//     }

//     // 统计当前场上特感数量 (活着 + 幽灵)
//     int currentSI = SD_GetSICount();
//     for (int i = 1; i <= 6; i++)
//         currentSI += g_iSpawnGhosts[i];

//     // [关键阈值]
//     // 只有当场上特感几乎死光 (<= 1只)，且队列也是空的
//     // 才触发下一波"全军出击"
//     int waveThreshold = g_cvMaxSI;

//     if (currentSI <= waveThreshold && g_hSpawnQueue.Length == 0)
//     {
//         // 生成整编小队 (调用新函数)
//         SD_GenerateSquadWave();

//         // 更新最后刷新时间
//         g_fLastSupplyTime = time;

//         if (g_cvDebugMode.BoolValue)
//         {
//             SD_Log("[波次] 进攻波次已就绪！队列数: %d", g_hSpawnQueue.Length);
//         }
//     }

//     // 战术分析 (保留用于日志，但不影响刷怪)
//     // if (time >= g_fNextSpawnTime) {
//     //     g_fNextSpawnTime = time + g_cvSpawnInterval.FloatValue;
//     //     SD_AnalyzeTacticalState();
//     // }

//     return Plugin_Continue;
// }
// public Action Timer_DirectorThink(Handle timer) {
//     if (!g_bLeftSafeArea) return Plugin_Continue;
//     if (!SD_IsSurvivorTeamAlive()) return Plugin_Continue;

//     g_iCachedBestTarget = SD_GetBestStrategicTarget();

//     // [高级优化] 分频处理：清理逻辑没必要每帧都跑
//     // 0.1s * 5 = 0.5s 执行一次清理，节省 80% 的清理开销
//     static int tickCounter = 0;
//     if (++tickCounter >= 5) {
//         SD_CullLaggingSI_Fast();
//         tickCounter = 0;
//     }
//     float time = GetEngineTime();

//     // 1. Tank 逻辑 (保持不变)
//     if (g_cvEnableTankControl.BoolValue) {
//         if (!g_bTankSpawnedRound && time > g_fNextTankTime && !SD_IsTankAlive()) {
//             if (GetRandomInt(1, 100) <= g_cvTankChance.IntValue) {
//                 int target = SD_GetBestStrategicTarget();
//                 if (target > 0) SD_AttemptTankAssault(target);
//             }
//         }
//     }

//     // =========================================================
//     // [核心修改] 波次刷新逻辑 + 惊喜模式
//     // =========================================================

//     // 统计当前场上特感数量 (活着 + 幽灵)
//     int currentSI = SD_GetSICount();
//     for(int i=1; i<=6; i++) currentSI += g_iSpawnGhosts[i];

//     // 用于记录上一帧的特感数量，检测“团灭瞬间”
//     static int lastFrameSICount = 0;

//     // 判断是否处于冷却中
//     bool isCoolingDown = ((time - g_fLastSupplyTime) < g_cvHungerCooldown.FloatValue);

//     // --- [新增] 惊喜判定逻辑 ---
//     // 触发条件：
//     // 1. 上一帧还有怪 (last > 0) -> 这一帧没了 (current == 0) [检测到团灭瞬间]
//     // 2. 且 队列是空的
//     // 3. 且 处于冷却中 (即正常流程不会刷怪)
//     // 4. 且 骰子中了
//     if (lastFrameSICount > 0 && currentSI == 0 && g_hSpawnQueue.Length == 0) {
//         if (isCoolingDown) {
//             int chance = g_cvSurpriseChance.IntValue;
//             if (chance > 0 && GetRandomInt(1, 100) <= chance) {

//                 // 触发惊喜！
//                 SD_GenerateSurpriseWave(); // 生成全控
//                 SD_TriggerSurpriseMob();   // 召唤尸潮

//                 // 重置冷却时间为当前时间
//                 // 这样等这一波惊喜死完后，系统会重新开始计算冷却，避免无限连刷
//                 g_fLastSupplyTime = time;

//                 // 更新状态并退出，等待 ProcessQueue 处理队列
//                 lastFrameSICount = currentSI;
//                 return Plugin_Continue;
//             }
//         }
//     }

//     // 更新历史记录
//     lastFrameSICount = currentSI;

//     // --- 正常刷新逻辑 ---

//     // 如果还在冷却，就暂停
//     if (isCoolingDown) {
//         return Plugin_Continue;
//     }

//     // [关键阈值] 正常补货
//     // 只有当场上特感几乎死光 (<= 1只)，且队列也是空的
//     int waveThreshold = g_cvMaxSI.IntValue; // 建议保持为 1

//     if (currentSI <= waveThreshold && g_hSpawnQueue.Length == 0) {

//         SD_GenerateSquadWave();

//         g_fLastSupplyTime = time;

//         if (g_cvDebugMode.BoolValue) {
//             SD_Log("[波次] 进攻波次已就绪！队列数: %d", g_hSpawnQueue.Length);
//         }
//     }

//     return Plugin_Continue;
// }
// public Action Timer_DirectorThink(Handle timer) {
//     if (!g_bLeftSafeArea) return Plugin_Continue;
//     if (!SD_IsSurvivorTeamAlive()) return Plugin_Continue;

//     SD_CullLaggingSI_Fast();
//     float time = GetEngineTime();

//     // 1. Tank 逻辑 (保持不变)
//     if (g_cvEnableTankControl.BoolValue) {
//         if (!g_bTankSpawnedRound && time > g_fNextTankTime && !SD_IsTankAlive()) {
//             if (GetRandomInt(1, 100) <= g_cvTankChance.IntValue) {
//                 int target = SD_GetBestStrategicTarget();
//                 if (target > 0) SD_AttemptTankAssault(target);
//             }
//         }
//     }

//     // =========================================================
//     // [核心修改] 波次刷新逻辑 (Wave Spawn)
//     // =========================================================

//     // 检查冷却
//     if ((time - g_fLastSupplyTime) < g_cvHungerCooldown.FloatValue) {
//         return Plugin_Continue;
//     }

//     // 统计当前场上特感数量 (活着 + 幽灵)
//     int currentSI = SD_GetSICount();
//     for(int i=1; i<=6; i++) currentSI += g_iSpawnGhosts[i];

//     // [关键阈值]
//     // 只有当场上特感几乎死光 (<= 1只)，且队列也是空的
//     // 才触发下一波"全军出击"
//     int waveThreshold = g_cvMaxSI.IntValue - 2;

//     if (currentSI <= waveThreshold && g_hSpawnQueue.Length == 0) {

//         // 生成整编小队 (调用新函数)
//         SD_GenerateSquadWave();

//         // 更新最后刷新时间
//         g_fLastSupplyTime = time;

//         if (g_cvDebugMode.BoolValue) {
//             SD_Log("[波次] 进攻波次已就绪！队列数: %d", g_hSpawnQueue.Length);
//         }
//     }

//     // 战术分析 (保留用于日志，但不影响刷怪)
//     // if (time >= g_fNextSpawnTime) {
//     //     g_fNextSpawnTime = time + g_cvSpawnInterval.FloatValue;
//     //     SD_AnalyzeTacticalState();
//     // }

//     return Plugin_Continue;
// }
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

    // [动态冷却] 根据存活人数自动调整补货间隔
    float dynamicCD = SD_GetDynamicCooldown();
    if ((time - g_fLastSupplyTime) < dynamicCD) return Plugin_Continue;

    int currentTotal = SD_GetTotalSI_Strict();
    int maxSI        = g_cvMaxSI.IntValue;

    if (currentTotal >= maxSI || g_hSpawnQueue.Length > 0) return Plugin_Continue;

    SD_GenerateSquadWave();
    // =========================================================
    // [难度系统] 特殊尸潮机制
    // =========================================================
    int currentTier = g_cvDifficultyTier.IntValue;

    // 第5/6档：Tank 存活时的无限尸潮 (15秒一波)
    if (currentTier >= 5 && SD_IsTankAlive())
    {
        if ((time - g_fLastTankMobTime) > 15.0)
        {
            g_fLastTankMobTime = time;
            SD_TriggerSurpriseMob();
            if (g_cvDebugMode.BoolValue) SD_Log("[第%d档] Tank存活，强制触发15s循环尸潮！", currentTier);
        }
    }
    // ---------------------------------------------------------
    // [终极绝杀] 96% 进度拌线：大清洗与瞬间拦截 (无论几档都可触发，或者你可以加个档位限制)
    // ---------------------------------------------------------
    int bestSurv = GetHighestFlowSurvivorSafe();
    int pct      = 0;
    if (IsValidSurvFast(bestSurv) && TryGetClientFlowPercentSafe(bestSurv, pct))
    {
        // 如果进度达到 96%，且这局还没触发过拦截
        if (pct >= 97 && !g_bTerminalIntercept)
        {
            g_bTerminalIntercept = true;    // 锁死开关，本局只执行一次绝杀
            int   culledCount    = 0;
            float leaderFlow     = g_fFlowCache[bestSurv];

            // 1. 终极无情大清洗
            for (int i = 1; i <= MaxClients; i++)
            {
                if (g_iInfectedMask & (1 << i))
                {
                    int victim = SD_GetSIVictim(i);
                    if (victim > 0)
                    {
                        // 控到人，但被控者倒地了 -> 无情处死，不要在将死之人身上浪费时间！
                        if (g_bIsIncap[victim])
                        {
                            ForcePlayerSuicide(i);
                            culledCount++;
                        }
                    }
                    else
                    {
                        // 没控到人，且处于领头羊的后方 -> 处死！
                        float siFlow = L4D2Direct_GetFlowDistance(i);
                        if (siFlow != -9999.0 && siFlow < leaderFlow)
                        {
                            ForcePlayerSuicide(i);
                            culledCount++;
                        }
                    }
                }
            }

            // 2. 瞬间爆兵：清空烂账，强制生成全控特感
            g_hSpawnQueue.Clear();
            for (int i = 0; i < maxSI; i++)
            {
                // 全部塞入硬控（牛/猴/舌/猎），不要胖子和口水了，终点前只要强控
                g_hSpawnQueue.Push(SD_PickRandomPinner());
            }
            SD_ShuffleQueue(g_hSpawnQueue);

            // 3. [极其关键] 剥夺冷却时间
            // 把最后供货时间重置为 0，这会导致 Timer_ProcessQueue 瞬间像疯狗一样开始派单
            g_fLastSupplyTime  = 0.0;
            g_fLastTankMobTime = time;    // 顺手召唤一波尸潮
            SD_TriggerSurpriseMob();

            // 4. 气势拉满的提示
            // PrintToChatAll("\x04[Sion]\x01 警告：\x03检测到生还者逼近终点，启动终局拦截程序！");
            if (g_cvDebugMode.BoolValue)
            {
                SD_Log("[终局绝杀] 96%% 拌线触发！处死了 %d 只没用的特感，瞬间向前方空投全控阵容！", culledCount);
            }
        }
    }

    // 第6档专属：进度达到 95% 时无限暴走 (10秒一波)
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
    // =========================================================

    if (g_hSpawnQueue.Length > 0)
    {
        g_fLastSupplyTime = time;

        // 第2档及以上才允许触发平时的伴随尸潮
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
// [核心修改] 定时波次 + 概率尸潮
// public Action Timer_DirectorThink(Handle timer)
// {
//     // 1. 基础状态检查
//     if (!g_bLeftSafeArea) return Plugin_Continue;
//     if (!SD_IsSurvivorTeamAlive()) return Plugin_Continue;

//     float time = GetEngineTime();

//     // =========================================================
//     // [关键修复] 安全阀 (Watchdog) - 必须放在任何生成逻辑之前
//     // =========================================================
//     // 只有在"休息期"（队列为空）才检查。
//     // 如果距离上次补货超过5秒，队列也是空的，但 Pending 还不为0，说明卡单了。
//     if (g_hSpawnQueue.Length == 0)
//     {
//         if ((time - g_fLastSupplyTime) > 5.0)
//         {
//             if (g_iTotalPending > 0)
//             {
//                 if (g_cvDebugMode.BoolValue)
//                 {
//                     SD_Log("[Safety] 检测到 Pending 烂账: %d 个. 强制修正为 0.", g_iTotalPending);
//                 }
//                 g_iTotalPending = 0;    // 强制归零，防止永久占位
//             }
//         }
//     }

//     // 2. 清理卡住的特感
//     SD_CullLaggingSI_Fast();

//     // =========================================================
//     // 波次刷新 + 概率尸潮逻辑
//     // =========================================================

//     // 3. 严格的时间检查 (不到时间绝对不刷)
//     if ((time - g_fLastSupplyTime) < g_cvHungerCooldown.FloatValue)
//     {
//         return Plugin_Continue;
//     }

//     // 4. 检查空位 (防止溢出)
//     // 此时 SD_GetTotalSI_Strict() 会包含 g_iTotalPending (此时它已经被安全阀修正过了，是准确的)
//     int currentTotal = SD_GetTotalSI_Strict();
//     int maxSI        = g_cvMaxSI.IntValue;

//     if (currentTotal >= maxSI || g_hSpawnQueue.Length > 0)
//     {
//         return Plugin_Continue;
//     }

//     // 5. 触发特感生成 (填满队列)
//     SD_GenerateSquadWave();

//     // 6. 只要成功生成了特感任务（意味着新的一波开始了）
//     if (g_hSpawnQueue.Length > 0)
//     {
//         g_fLastSupplyTime = time;    // 重置补货冷却

//         // --- [伴随尸潮逻辑] ---
//         // 只有在特感进攻时，才顺便判定是否起尸潮

//         // 检查冷却：只有 (当前时间 - 上次尸潮时间) > 冷却设定值 时
//         if ((time - g_fLastMobTime) > g_cvmobcooldown.FloatValue)
//         {
//             // 获取当前路程的前方尸潮概率
//             int mobChance = GetLogicChance_MobFront();

//             // 掷骰子判定
//             if (mobChance > 0 && GetRandomInt(1, 100) <= mobChance)
//             {
//                 // 触发前方尸潮！
//                 SD_TriggerSurpriseMob();

//                 // [关键] 更新最后触发时间，重置 CD
//                 g_fLastMobTime = time;

//                 if (g_cvDebugMode.BoolValue)
//                 {
//                     SD_Log("[导演] 路程尸潮判定成功! (概率: %d%%) -> 尸潮伴随进攻", mobChance);
//                 }
//             }
//             else
//             {
//                 // 概率没中
//                 if (g_cvDebugMode.BoolValue)
//                 {
//                     SD_Log("[波次] 标准特感波次 (无尸潮 - 概率未中). 下次: %.1f秒", g_cvHungerCooldown.FloatValue);
//                 }
//             }
//         }
//         else
//         {
//             // 还在冷却中
//             if (g_cvDebugMode.BoolValue)
//             {
//                 float remaining = g_cvmobcooldown.FloatValue - (time - g_fLastMobTime);
//                 SD_Log("[波次] 标准特感波次 (尸潮冷却中: 剩余 %.1f秒).", remaining);
//             }
//         }
//     }

//     // =========================================================
//     // Tank 逻辑 (保持不变)
//     // =========================================================
//     if (g_cvEnableTankControl.BoolValue)
//     {
//         if (!g_bTankSpawnedRound && time > g_fNextTankTime && !SD_IsTankAlive())
//         {
//             if (GetRandomInt(1, 100) <= g_cvTankChance.IntValue)
//             {
//                 int target = SD_GetBestStrategicTarget();
//                 if (target > 0) SD_AttemptTankAssault(target);
//             }
//         }
//     }

//     return Plugin_Continue;
// }
public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{
    // 1. [新增] 尸潮方向控制 (惊喜模式)
    if (g_bForceMobFront && StrEqual(key, "PreferredMobDirection", false))
    {
        retVal = 7;    // SPAWN_IN_FRONT_OF_SURVIVORS
        return Plugin_Handled;
    }

    // 2. [原有] 配合你自定义的寻位逻辑
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

    // ==========================================================
    // 3. [核心剥夺] 彻底切断原生导演的特感刷新能力！
    // 只要原生导演（或地图机关）试图查询配额，永远返回 0。
    // ==========================================================
    switch (key[0])
    {
        case 'M':
        {
            // 屏蔽总上限
            if (StrEqual(key, "MaxSpecials", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
        case 'c':
        {
            // 屏蔽突变模式总上限
            if (key[3] == 'M' && StrEqual(key, "cm_MaxSpecials", false))
            {
                retVal = 0;
                return Plugin_Handled;
            }
        }
        case 'D':
        {
            // 屏蔽控制类上限
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

        // --- 剥夺所有单类特感的原生配额 ---
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
// [核心] 缓存更新函数 (必须替换原版)
void UpdateClientCache(int client)
{
    if (IsValidClient(client))
    {
        g_bCachedInGame[client] = true;
        g_iCachedTeam[client]   = GetClientTeam(client);
        g_bCachedAlive[client]  = IsAlive(client);

        int maskBit             = (1 << client);

        // 更新生还者掩码
        if (g_iCachedTeam[client] == TEAM_SURVIVOR && g_bCachedAlive[client])
        {
            g_iSurvivorMask |= maskBit;    // 标记为 1
        }
        else {
            g_iSurvivorMask &= ~maskBit;    // 标记为 0
        }

        // 更新特感掩码 (注意：通常我们不把 Tank 算作普通特感)
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
        // 客户端无效/断开时的清理
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
        UpdateClientCache(i);    // 重建掩码
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

            // [优化] 使用 true 参数获取平方距离，比较 100*100 = 10000
            // 避免了 expensive 的 sqrt 运算
            if (GetVectorDistance(currentPos, g_vLastFlowPos[i], true) > 10000.0)
            {
                float safeFlow;
                // 只有获取到真实安全的进度，才覆盖缓存。如果是断层，保留上一次的正确进度
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
            // if (g_bIsBiled[i]) continue;
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
void SD_CullLaggingSI_Fast()
{
    if (g_iInfectedMask == 0) return;

    // [核心修复 2] 动态保护：处死距离绝对不能小于你的最大生成距离！
    float cullDist    = g_cvCullDistance.FloatValue;
    float safeMinDist = g_cvSpawnDistMax.FloatValue + 300.0;    // 留出 300 码的缓冲区
    if (cullDist < safeMinDist) cullDist = safeMinDist;

    float cullDistSq        = cullDist * cullDist;
    // 前方特感的容忍度放宽到 3 倍，防止辛苦跑图刷出来的前方怪被杀
    float cullDistSqForward = (cullDist * 3.0) * (cullDist * 3.0);

    float time              = GetEngineTime();
    float leaderFlow        = 0.0;
    int   activeSurvivors   = 0;

    // 找 Leader Flow
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
            // 刚刷出来 8 秒内绝对不清理 (给足落地和寻路时间)
            if (time - g_fSpawnTime[i] < 8.0) continue;
            // 正在控人的特感绝对不杀
            if (SD_IsSIPinning(i)) continue;

            // =======================================================
            // [终极修复] 原地罚站强制抹杀（带防误杀判定）
            // =======================================================
            // if (!IsFakeClient(i)) continue;    // 保护真人特感玩家

            float vel[3];
            GetEntPropVector(i, Prop_Data, "m_vecVelocity", vel);
            float speedSq   = vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2];

            // 发呆容忍时间 = 补货冷却时间 + 8秒的跑图容忍度 (保证处死后秒补怪)
            float idleLimit = g_cvHungerCooldown.FloatValue + 4;

            if (speedSq < 15.0 && (time - g_fSpawnTime[i] > idleLimit))
            {
                float siFlow = L4D2Direct_GetFlowDistance(i);

                // 【核心改良】：增加前后方判定
                // 如果 siFlow < leaderFlow，说明在后方挂机/卡墙/被垫底生还者溜。该杀！
                // 如果 siFlow >= leaderFlow，说明是在前方准备阴人（比如蹲角落），继续留着！
                if (siFlow != -9999.0 && siFlow < leaderFlow)
                {
                    ForcePlayerSuicide(i);
                    continue;    // 已经处死，直接跳过后续判断
                }
            }
            // =======================================================

            float siPos[3];
            GetClientAbsOrigin(i, siPos);
            float nearestActiveDistSq = 9999999999.0;

            // 检查最近的生还者距离
            for (int j = 1; j <= MaxClients; j++)
            {
                if ((g_iSurvivorMask & (1 << j)) && !g_bIsIncap[j])
                {
                    float dSq = GetVectorDistance(siPos, g_vLastFlowPos[j], true);
                    if (dSq < nearestActiveDistSq) nearestActiveDistSq = dSq;
                }
            }

            // 距离生还者足够近，说明已参战且正在移动（因为上面的罚站检测没杀它），不清理
            if (nearestActiveDistSq < cullDistSq) continue;

            float siFlow   = L4D2Direct_GetFlowDistance(i);
            bool  isBehind = (siFlow != -9999.0 && siFlow < leaderFlow);

            // [逻辑分流]
            if (isBehind)
            {
                // 1. 落后处死：只要它被甩在队伍后面，且距离 > cullDist，立刻处死腾槽位
                ForcePlayerSuicide(i);
                continue;
            }
            else
            {
                // 2. 视野检测保护：即使在前方，只要被玩家看到了就留着它
                if (GetEntProp(i, Prop_Send, "m_hasVisibleThreats") > 0) continue;

                // 3. 前方过远处死：只有当它在正前方且离玩家极远 (3倍处死距离外)，才杀掉防止卡图
                if (nearestActiveDistSq > cullDistSqForward)
                {
                    ForcePlayerSuicide(i);
                    continue;
                }
            }
        }
    }
}
// void SD_CullLaggingSI_Fast()
// {
//     if (g_iInfectedMask == 0) return;

//     // [核心修复 2] 动态保护：处死距离绝对不能小于你的最大生成距离！
//     float cullDist = g_cvCullDistance.FloatValue;
//     float safeMinDist = g_cvSpawnDistMax.FloatValue + 300.0; // 留出 300 码的缓冲区
//     if (cullDist < safeMinDist) cullDist = safeMinDist;

//     float cullDistSq         = cullDist * cullDist;
//     // 前方特感的容忍度放宽到 3 倍，防止辛苦跑图刷出来的前方怪被杀
//     float cullDistSqForward  = (cullDist * 3.0) * (cullDist * 3.0);

//     float time               = GetEngineTime();
//     float leaderFlow         = 0.0;
//     int   activeSurvivors    = 0;

//     // 找 Leader Flow
//     for (int i = 1; i <= MaxClients; i++)
//     {
//         if ((g_iSurvivorMask & (1 << i)) && !g_bIsIncap[i])
//         {
//             float f = g_fFlowCache[i];
//             if (f > leaderFlow) leaderFlow = f;
//             activeSurvivors++;
//         }
//     }
//     if (activeSurvivors == 0) leaderFlow = g_fLastMaxFlow;

//     for (int i = 1; i <= MaxClients; i++)
//     {
//         if (g_iInfectedMask & (1 << i))
//         {
//             // 刚刷出来 10 秒内绝对不清理
//             if (time - g_fSpawnTime[i] < 8.0) continue;
//             if (SD_IsSIPinning(i)) continue;

//             float siPos[3];
//             GetClientAbsOrigin(i, siPos);
//             float nearestActiveDistSq = 9999999999.0;

//             // 检查最近的生还者距离
//             for (int j = 1; j <= MaxClients; j++)
//             {
//                 if ((g_iSurvivorMask & (1 << j)) && !g_bIsIncap[j])
//                 {
//                     float dSq = GetVectorDistance(siPos, g_vLastFlowPos[j], true);
//                     if (dSq < nearestActiveDistSq) nearestActiveDistSq = dSq;
//                 }
//             }

//             // 距离生还者足够近，说明已参战，不清理
//             if (nearestActiveDistSq < cullDistSq) continue;

//             float siFlow = L4D2Direct_GetFlowDistance(i);
//             bool isBehind = (siFlow != -9999.0 && siFlow < leaderFlow);

//             // [逻辑分流]
//             if (isBehind)
//             {
//                 // 1. 落后处死：只要它被甩在队伍后面，且距离 > cullDist，立刻处死腾槽位
//                 ForcePlayerSuicide(i);
//                 continue;
//             }
//             else
//             {
//                 // 2. 视野检测保护：即使在前方，只要被玩家看到了就留着它
//                 if (GetEntProp(i, Prop_Send, "m_hasVisibleThreats") > 0) continue;

//                 // [核心修复 3] 前方过远处死：只有当它在正前方发呆且离玩家极远 (3倍处死距离外)，才杀掉防止卡图
//                 if (nearestActiveDistSq > cullDistSqForward)
//                 {
//                     ForcePlayerSuicide(i);
//                     continue;
//                 }
//             }
//         }
//     }
// }
// void SD_CullLaggingSI_Fast()
// {
//     // 如果掩码为0，说明没特感，直接跳过
//     if (g_iInfectedMask == 0) return;

//     float cullDist = g_cvCullDistance.FloatValue;
//     if (cullDist < 800.0) cullDist = 800.0;
//     float cullDistSq         = cullDist * cullDist;
//     float cullDistSqExtended = (cullDist * 1.5) * (cullDist * 1.5);
//     float time               = GetEngineTime();
//     float leaderFlow         = 0.0;
//     int   activeSurvivors    = 0;

//     // 找 Leader Flow
//     for (int i = 1; i <= MaxClients; i++)
//     {
//         if ((g_iSurvivorMask & (1 << i)) && !g_bIsIncap[i])
//         {
//             float f = g_fFlowCache[i];
//             if (f > leaderFlow) leaderFlow = f;
//             activeSurvivors++;
//         }
//     }
//     if (activeSurvivors == 0) leaderFlow = g_fLastMaxFlow;

//     // [优化] 直接遍历特感掩码，不通过 Native 循环
//     for (int i = 1; i <= MaxClients; i++)
//     {
//         // 只要位是 1，就说明：在游戏里活着有特感
//         if (g_iInfectedMask & (1 << i))
//         {
//             // 刚刷出来 10 秒内不清理
//             if (time - g_fSpawnTime[i] < 10.0) continue;
//             if (SD_IsSIPinning(i)) continue;

//             float siPos[3];
//             GetClientAbsOrigin(i, siPos);
//             float nearestActiveDistSq = 9999999999.0;

//             // 检查所有生还者距离
//             for (int j = 1; j <= MaxClients; j++)
//             {
//                 if ((g_iSurvivorMask & (1 << j)) && !g_bIsIncap[j])
//                 {
//                     float dSq = GetVectorDistance(siPos, g_vLastFlowPos[j], true);
//                     if (dSq < nearestActiveDistSq) nearestActiveDistSq = dSq;
//                 }
//             }

//             if (nearestActiveDistSq < cullDistSq) continue;

//             // 落后者清理
//             float siFlow = L4D2Direct_GetFlowDistance(i);
//             if (siFlow != -9999.0 && siFlow < leaderFlow)
//             {
//                 ForcePlayerSuicide(i);
//                 continue;
//             }

//             // 视野检测清理
//             if (GetEntProp(i, Prop_Send, "m_hasVisibleThreats") > 0) continue;
//             if (nearestActiveDistSq > cullDistSqExtended)
//             {
//                 ForcePlayerSuicide(i);
//                 continue;
//             }
//         }
//     }
// }
// void SD_AttemptTankAssault(int target)
// {
//     // 1. 基础检查：如果有 Tank 了、或者目标无效，直接退出
//     if (g_bTankSpawnedRound || SD_IsTankAlive() || target <= 0) return;

//     float pos[3];    // 用于接收坐标

//     // 2. 调用你的新寻位函数
//     // 建议：minRange 设为 600.0 (太近会刷脸)，maxRange 设为 1500.0 (太远赶不过来)
//     // 函数返回 true 说明找到了位置，坐标已存入 pos
//     if (SD_FindNavSpawnPos_Advanced(target, 400.0, 1500.0, false, pos))
//     {
//         // 3. 生成逻辑
//         // 注意：pos 已经被上面的函数赋值了，直接传给 L4D2_SpawnTank
//         L4D2_SpawnTank(pos, NULL_VECTOR);

//         // 标记本回合已生成
//         g_bTankSpawnedRound = true;

//         PrintToChatAll("\x04[Sion]\x01 警告：\x03TANK \x01已入场，本局只有这一只！");

//         // 4. 触发伴随尸潮 (保持原逻辑)
//         int flags = GetCommandFlags("z_spawn_old");
//         SetCommandFlags("z_spawn_old", flags & ~FCVAR_CHEAT);
//         FakeClientCommand(target, "z_spawn_old mob");
//         SetCommandFlags("z_spawn_old", flags);

//         // 5. 生成一波伴随特感
//         SD_GenerateSurpriseWave();
//     }
//     // else { 如果没找到点，这里可以留空，下一帧导演会继续尝试 }
// }
void SD_AttemptTankAssault(int target)
{
    if (g_bTankSpawnedRound || SD_IsTankAlive() || target <= 0) return;
    float pos[3];

    if (SD_FindNavSpawnPos_Advanced(target, 400.0, 1500.0, false, pos))
    {
        L4D2_SpawnTank(pos, NULL_VECTOR);
        g_bTankSpawnedRound = true;
        PrintToChatAll("\x04[Sion]\x01 \x03TANK \x01已入场，本局只有这一只！");

        // [难度系统] 第2档及以上，出克才附赠一波普通尸潮
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
// [核心] 尝试生成 (引擎内核 + 视线过滤 + API控制)
// rangeOverride: 允许覆盖默认距离，传入 -1.0 则使用 g_cvSpawnDistMax
bool SD_AttemptEngineSpawn(int zClass, int target, float rangeOverride = -1.0)
{
    // 1. 目标校验
    // 如果传入的目标无效，则自动回退到"路程最远"的生还者
    if (target <= 0 || !IsClientInGame(target) || !IsPlayerAlive(target) || GetClientTeam(target) != 2)
    {
        target = L4D_GetHighestFlowSurvivor();
        if (target <= 0) return false;    // 实在没人了
    }

    // 2. 准备修改引擎参数
    ConVar cvRange = FindConVar("z_spawn_range");
    ConVar cvSafe  = FindConVar("z_safe_spawn_range");

    if (cvRange == null || cvSafe == null) return false;    // 防御性编程

    int oldRange = cvRange.IntValue;
    int oldSafe  = cvSafe.IntValue;

    // 确定搜索半径
    int searchRange;
    if (rangeOverride > 0.0)
    {
        searchRange = RoundToCeil(rangeOverride);
    }
    else
    {
        searchRange = g_cvSpawnDistMax.IntValue;
    }

    // 兜底最小值，防止引擎无法计算
    if (searchRange < 250) searchRange = 250;

    // [HACK] 修改引擎 CVar
    cvRange.SetInt(searchRange);
    cvSafe.SetInt(0);    // 关键：允许引擎找"看得见"的点 (为了贴脸)，后面由我们自己过滤

    // 3. 开启 Hook 开关 (让插件接管 Spawn 位置判断)
    g_bIsPluginSpawning = true;

    float pos[3];
    bool  validSpotFound = false;

    // [抽卡机制] 给引擎 10 次机会
    // 因为 safe_range=0，引擎很容易找到点，我们需要用视线检测过滤掉不合格的
    for (int i = 0; i < 10; i++)
    {
        // 请求引擎找点 (参数3是尝试次数，这里传小一点因为我们在外层有循环)
        if (L4D_GetRandomPZSpawnPosition(target, zClass, 5, pos))
        {
            // [视线检测]
            // 如果被看见了(返回true)，则 continue 重试
            if (SD_IsPosVisible(pos, target))
            {
                continue;
            }

            // 通过检测！
            validSpotFound = true;
            break;
        }
    }

    bool spawned = false;

    if (validSpotFound)
    {
        // 稍微抬高防止卡地板
        pos[2] += 5.0;

        // 直接生成，不经过 SD_ExecuteSpawn (避免重复日志或逻辑)
        int zombie = L4D2_SpawnSpecial(zClass, pos, NULL_VECTOR);
        if (zombie > 0 && IsPlayerAlive(zombie))
        {
            spawned              = true;

            // 自动蹲下 (防止瞬间暴露，增加伏击感)
            g_fSpawnTime[zombie] = GetEngineTime();        // 补发8秒免死保护
            if (g_iTotalPending > 0) g_iTotalPending--;    // 顺手解决我上次提到的烂账卡单问题
            // ======================

            // SetEntProp(zombie, Prop_Send, "m_bDucked", 1);
            // SetEntityFlags(zombie, GetEntityFlags(zombie) | FL_DUCKING);

            // 日志
            if (g_cvDebugMode.BoolValue)
            {
                SD_LogSpawnEvent(zClass, target, pos);
            }

            // 幽灵计数管理
            g_iSpawnGhosts[zClass]++;
            CreateTimer(0.5, Timer_ClearGhost, zClass, TIMER_FLAG_NO_MAPCHANGE);
        }
    }

    // 4. [重要] 还原现场，无论成功失败
    g_bIsPluginSpawning = false;
    cvRange.SetInt(oldRange);
    cvSafe.SetInt(oldSafe);

    return spawned;
}

// bool SD_SpawnWithNavBucket(int class, int target)
// {
//     float pos[3];
//     float distMin = g_cvSpawnDistMin.FloatValue;
//     float distMax = g_cvSpawnDistMax.FloatValue;
//     bool  reqVis  = true;
//     bool  isGrief = false;

//     if (target > 0 && IsClientInGame(target) && !IsFakeClient(target))
//     {
//         char auth[64];
//         GetClientAuthId(target, AuthId_Steam2, auth, sizeof(auth));

//         // 1. 最高管理员 (绝对免疫)
//         if (StrEqual(auth, SUPER_ADMIN_STEAMID))
//         {
//             // 保持正常游戏，不做任何恶搞
//         }
//         // 2. 常驻倒霉蛋 (受苦，但受开关控制)
//         // [修改] 增加了 g_cvGriefPermanentEnv.BoolValue 判断
//         else if (g_cvGriefPermanentEnv.BoolValue && StrEqual(auth, PERMANENT_VICTIM))
//         {
//             distMin = 50.0;
//             distMax = 350.0;
//             reqVis  = false;
//             isGrief = true;
//         }
//         // 3. 动态名单 (文件列表)
//         else if (g_hGriefTargets.FindString(auth) != -1)
//         {
//             distMin = 50.0;
//             distMax = 350.0;
//             reqVis  = false;
//             isGrief = true;
//         }
//     }

//     // --- 调用寻位函数 ---
//     // 注意第四个参数传入了 reqVis
//     if (SD_FindNavSpawnPos_Advanced(target, distMin, distMax, reqVis, pos))
//     {
//         if (isGrief) PrintToChat(target, "\x04[Sion]\x01 \x03Surprise! \x01(无视视野生成)");

//         // 执行生成
//         return SD_ExecuteSpawn(class, target, pos);
//     }
//     // 1.1 标准距离尝试
//     // if (SD_FindNavSpawnPos_Advanced(target, distMin, distMax, pos))
//     // {
//     //     return SD_ExecuteSpawn(class, target, pos);
//     // }
//     if (SD_AttemptEngineSpawn(class, target, distMin))
//     {
//         return true;
//     }

//     if (SD_AttemptEngineSpawn(class, target, distMax))
//     {
//         return true;
//     }

//     return false;
// }
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
        { /* 免死 */
        }
        else if (g_cvGriefPermanentEnv.BoolValue && StrEqual(auth, PERMANENT_VICTIM))
        {
            distMin = 50.0;
            distMax = 350.0;
            reqVis  = false;
            isGrief = true;
        }
        else if (g_hGriefTargets.FindString(auth) != -1)
        {
            distMin = 50.0;
            distMax = 350.0;
            reqVis  = false;
            isGrief = true;
        }
    }

    // [难度系统] 第5/6档：胖子极速贴脸 (无视视野，卡在 50~150 码内)
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
// bool SD_SpawnWithNavBucket(int class, int target)
// {
//     float pos[3];
//     int   strategy = g_cvSpawnStrategy.IntValue;

//     // 策略 1 (Nav) 或 0 (Hybrid)
//     if (strategy != 2)
//     {
//         if (SD_FindNavSpawnPos_Advanced(class, target, g_cvSpawnDistMin.FloatValue, g_cvSpawnDistMax.FloatValue, pos))
//         {
//             return SD_ExecuteSpawn(class, target, pos);
//         }
//         if (SD_FindNavSpawnPos_Advanced(class, target, g_cvSpawnDistMax.FloatValue, g_cvSpawnDistMax.FloatValue + 400.0, pos))
//         {
//             return SD_ExecuteSpawn(class, target, pos);
//         }
//         // 强制 Nav 且失败 -> 放弃
//         if (strategy == 1) return false;
//     }

//     // 策略 2 (Engine) 或 0 (Hybrid 兜底)
//     if (L4D_GetRandomPZSpawnPosition(target, 8, 10, pos))
//     {
//         return SD_ExecuteSpawn(class, target, pos);
//     }
//     return false;
// }

// 辅助执行生成 (避免重复代码)
// bool SD_ExecuteSpawn(int class, int target, float pos[3])
// {
//     // 稍微抬高防止卡地板
//     pos[2] += 5.0;

//     int zombie = L4D2_SpawnSpecial(class, pos, NULL_VECTOR);
//     if (zombie > 0 && IsPlayerAlive(zombie))
//     {
//         g_iSpawnGhosts[class]++;
//         CreateTimer(0.5, Timer_ClearGhost, class, TIMER_FLAG_NO_MAPCHANGE);
//         if (g_cvDebugMode.BoolValue) SD_LogSpawnEvent(class, target, pos);
//         return true;
//     }
//     return false;
// }
bool SD_ExecuteSpawn(int class, int target, float pos[3])
{
    pos[2] += 2.0;
    int zombie = L4D2_SpawnSpecial(class, pos, NULL_VECTOR);
    if (zombie > 0 && IsPlayerAlive(zombie))
    {
        g_fSpawnTime[zombie] = GetEngineTime();    // 已经加了的精确时间

        // [新增] 瞬间销账，不再等待滞后的 Event
        if (g_iTotalPending > 0) g_iTotalPending--;

        g_iSpawnGhosts[class]++;
        CreateTimer(0.5, Timer_ClearGhost, class, TIMER_FLAG_NO_MAPCHANGE);
        if (g_cvDebugMode.BoolValue) SD_LogSpawnEvent(class, target, pos);
        return true;
    }
    return false;
}
// bool SD_ExecuteSpawn(int class, int target, float pos[3])
// {
//     // 稍微抬高防止卡地板
//     pos[2] += 5.0;
//     int zombie = L4D2_SpawnSpecial(class, pos, NULL_VECTOR);
//     if (zombie > 0 && IsPlayerAlive(zombie))
//     {
//         // [核心修复 1] 绝对无延迟刷新出生时间，斩断旧槽位的时间残留
//         g_fSpawnTime[zombie] = GetEngineTime();

//         g_iSpawnGhosts[class]++;
//         CreateTimer(0.5, Timer_ClearGhost, class, TIMER_FLAG_NO_MAPCHANGE);
//         if (g_cvDebugMode.BoolValue) SD_LogSpawnEvent(class, target, pos);
//         return true;
//     }
//     return false;
// }
public Action Timer_ClearGhost(Handle timer, int class)
{
    // 只有大于0才减，防止减成负数
    if (g_iSpawnGhosts[class] > 0)
    {
        g_iSpawnGhosts[class]--;
    }
    return Plugin_Stop;
}

// =========================================================================
// 辅助函数
// =========================================================================
public bool TraceFilter_WorldOnly(int entity, int contentsMask) { return entity == 0; }

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    // [优化] 使用宏判定
    if (!IsValidInfFast(victim)) return Plugin_Continue;

    if (IsValidInfFast(attacker))
    {
        if (victim != attacker) return Plugin_Handled;    // 阻止特感互殴
        // 阻止胖子炸到队友
        if (GetEntProp(attacker, Prop_Send, "m_zombieClass") == ZC_BOOMER && (damagetype & DMG_BLAST)) return Plugin_Handled;
    }

    return Plugin_Continue;
}

// 使用缓存与位掩码
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
        // 使用缓存检查，避免 Native 调用
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
    float  maxs[3] = { 16.0, 16.0, 71.0 };    // 特感碰撞箱大小

    // [修改] 使用新的 TraceFilter_SpawnSanity 过滤器
    // MASK_PLAYERSOLID 会检测所有玩家会撞到的东西（包括门、车、空气墙）
    Handle trace   = TR_TraceHullFilterEx(pos, pos, mins, maxs, MASK_PLAYERSOLID, TraceFilter);

    bool   isStuck = TR_DidHit(trace);

    // 如果开启调试模式，且检测到卡住，画个红盒子看看卡哪了
    if (isStuck && g_cvDebugMode.BoolValue)
    {
        int hitEnt = TR_GetEntityIndex(trace);
        if (hitEnt > 0)
        {
            char cls[32];
            GetEntityClassname(hitEnt, cls, sizeof(cls));
            // PrintToServer("卡住在实体: %d (%s)", hitEnt, cls); // 调试用
        }
    }

    delete trace;

    if (isStuck) return false;    // 撞到东西了，不能刷

    // Nav 悬空检查 (原逻辑保留)
    Address navArea = L4D_GetNearestNavArea(pos, 60.0, false, false);
    if (navArea == Address_Null) return false;
    float navCenter[3];
    L4D_GetNavAreaCenter(navArea, navCenter);
    if (FloatAbs(pos[2] - navCenter[2]) > 35.0) return false;

    return true;
}
// [新增] 智能过滤器：忽略生物，但检测物理物件

/**
 * [日志系统] 升级版
 * 特性：按地图名自动分文件存储 + 刷怪分割线 + switch 逻辑修复
 */
void SD_LogSpawnEvent(int zClass, int target, float spawnPos[3])
{
    float targetEye[3];
    GetClientEyePosition(target, targetEye);
    float dist = GetVectorDistance(targetEye, spawnPos);

    // [优化] 查表法
    char  sName[16];
    if (zClass >= 1 && zClass <= 8) strcopy(sName, sizeof(sName), g_sClassNames[zClass]);
    else strcopy(sName, sizeof(sName), "Unknown");

    SD_Log("----------------------------------------------------------------");
    SD_Log("[生成] %-8s -> 目标: %-8N (距离: %5.1f) | 坐标: %.0f, %.0f, %.0f", sName, target, dist, spawnPos[0], spawnPos[1], spawnPos[2]);
}

void SD_Log(const char[] format, any...)
{
    if (g_cvDebugMode.IntValue < 1) return;

    // 1. 格式化原始消息
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);

    // 2. 加上时间戳
    char timeStr[32];
    FormatTime(timeStr, sizeof(timeStr), "%H:%M:%S");

    char finalMsg[1024];
    Format(finalMsg, sizeof(finalMsg), "[%s] %s", timeStr, buffer);

    // 3. [核心修改] 动态构建包含地图名的文件路径
    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));

    char path[PLATFORM_MAX_PATH];
    // 路径格式: logs/smart_director_c5m2_park.log
    BuildPath(Path_SM, path, sizeof(path), "logs/smart_director_%s.log", mapName);

    // 4. 写入文件
    LogToFileEx(path, "%s", finalMsg);
}

// [新增] 均衡选怪算法
int SD_PickBalancedPinner(bool useLimit, int limitCap)
{
    // 1. 定义所有控制类特感
    int candidates[]   = { ZC_SMOKER, ZC_HUNTER, ZC_JOCKEY, ZC_CHARGER };
    int candidateCount = 4;

    // 如果不启用限制，直接随机返回
    if (!useLimit)
    {
        return candidates[GetRandomInt(0, candidateCount - 1)];
    }

    // 2. 构建合格候选池 (Valid Pool)
    ArrayList validPool = new ArrayList();

    for (int i = 0; i < candidateCount; i++)
    {
        int cls          = candidates[i];

        // 统计该类特感目前的总数 = 场上活着的 + 队列里等待生成的
        int currentCount = SD_CountClass(cls) + SD_CountInQueue(cls);

        // 只有未达到限制的才加入候选池
        if (currentCount < limitCap)
        {
            validPool.Push(cls);
        }
    }

    // 3. 从候选池中随机抽取
    int result = ZC_HUNTER;    // 兜底默认值

    if (validPool.Length > 0)
    {
        result = validPool.Get(GetRandomInt(0, validPool.Length - 1));
    }
    else {
        // 如果所有职业都满员了（极少见），这就尴尬了。
        // 这种情况下被迫打破限制，随机选一个，或者选 Hunter (最不恶心人的特感)
        result = candidates[GetRandomInt(0, candidateCount - 1)];
    }

    delete validPool;
    return result;
}

// [辅助] 统计队列中某类特感的数量
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
// [核心修复] 生成波次任务
// void SD_GenerateSquadWave()
// {
//     // 1. 获取严谨的当前占用数 (存活 + 幽灵 + 队列)
//     // 只有这里算准了，才不会超生
//     int currentTotal = SD_GetTotalSI_Strict();
//     int maxSI        = g_cvMaxSI.IntValue;

//     // 2. 计算实际剩余空位
//     // 比如：上限8，场上活4，队列0 -> currentTotal=4 -> slotsNeeded=4
//     int slotsNeeded  = maxSI - currentTotal;

//     // 3. 如果没有空位（甚至超标），直接不生成，防止溢出
//     if (slotsNeeded <= 0)
//     {
//         // 可以在这里加个日志方便调试
//         // if (g_cvDebugMode.BoolValue) SD_Log("[波次] 场上已满 (%d/%d)，跳过生成。", currentTotal, maxSI);
//         return;
//     }

//     // 4. 清理队列 (防御性编程：虽然逻辑上这里应该是空的，但清一下更安全)
//     g_hSpawnQueue.Clear();

//     // --- [新功能集成] 获取基于 Flow 的全控概率 ---
//     // 下面会提供 GetLogicChance_FullControl 函数的实现
//     int pressureChance = GetLogicChance_FullControl();

//     bool forceFullControl = false;
//     // 掷骰子：如果小于概率，则强制全控
//     if (GetRandomInt(1, 100) <= pressureChance) {
//         forceFullControl = true;
//     }

//     int aoeType = 0;

//     // 5. 决定 AOE (胖子/口水)
//     // 规则：如果不强制全控，且场上没有AOE，且有足够的槽位（>1，留一个给控制特感）
//     if (!forceFullControl && (SD_CountClass(ZC_BOOMER) + SD_CountClass(ZC_SPITTER) == 0)) {
//         if (slotsNeeded > 1) {
//             aoeType = (GetRandomInt(0, 1) == 0) ? ZC_BOOMER : ZC_SPITTER;
//             g_hSpawnQueue.Push(aoeType);
//             slotsNeeded--; // 占用一个槽位
//         }
//     }

//     // 6. 填充剩下的位置 (slotsNeeded 现在是剩余的真实空位)
//     // 计算半数限制 (用于 PickBalancedPinner)
//     int halfLimit = maxSI >> 1;
//     if (halfLimit < 1) halfLimit = 1;

//     for (int i = 0; i < slotsNeeded; i++) {
//         // 使用你的均衡选怪函数
//         int pick = SD_PickBalancedPinner(g_cvLimitBatchHalf.BoolValue, halfLimit);
//         g_hSpawnQueue.Push(pick);
//     }

//     // 7. 打乱队列 (让 AOE 混在中间)
//     SD_ShuffleQueue(g_hSpawnQueue);

//     if (g_cvDebugMode.BoolValue) {
//         if (forceFullControl) {
//             SD_Log("[施压] 全控阵容! 概率:%d%% (路程进度导致)", pressureChance);
//         } else {
//             SD_Log("[波次] 标准阵容. AOE: %s", (aoeType == ZC_BOOMER) ? "胖子" : (aoeType == ZC_SPITTER) ? "口水" : "无");
//         }
//     }
// }
void SD_GenerateSquadWave()
{
    int maxSI        = g_cvMaxSI.IntValue;
    int currentTotal = SD_GetTotalSI_Strict();
    int slotsNeeded  = maxSI - currentTotal;

    if (slotsNeeded <= 0) return;

    int  fcChance      = GetLogicChance_FullControl();
    bool isFullControl = (GetRandomInt(1, 100) <= fcChance);

    // [难度系统] 第5/6档：Tank 存活时强行剥夺吐痰和胖子，全是硬控
    if (g_cvDifficultyTier.IntValue >= 5 && SD_IsTankAlive())
    {
        isFullControl = true;
    }

    if (g_cvDebugMode.BoolValue && isFullControl)
    {
        SD_Log("[导演] 全控阵容启动");
    }

    // int halfLimit = RoundToCeil(float(maxSI) / 2.0);
    int halfLimit = maxSI >> 1;    // 位运算代替除法，向下取整
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
            // [修改] 模拟一整波从四面八方刷出——对每个站立的生还者都触发幻听
            // 效果：全队同时听到不同方向的进攻声，以为被全方位包围
            for (int i = 1; i <= MaxClients; i++)
            {
                if (IsValidSurvFast(i) && !g_bIsIncap[i])
                    SD_PlayPhantomSound(i);
            }
        }
    }
}
// [核心修改] 生成波次任务 (融入路程概率 + 严谨的均衡算法)
// void SD_GenerateSquadWave()
// {
//     // 1. 获取需要填补的空位
//     int maxSI        = g_cvMaxSI.IntValue;
//     int currentTotal = SD_GetTotalSI_Strict();
//     int slotsNeeded  = maxSI - currentTotal;

//     if (slotsNeeded <= 0) return;

//     // 防御性清空，确保上一波烂账不会影响新波次
//     // g_hSpawnQueue.Clear();

//     // =========================================================
//     // [新逻辑] 路程概率判定：全控阵容 (Full Control)
//     // =========================================================
//     int  fcChance      = GetLogicChance_FullControl();
//     bool isFullControl = (GetRandomInt(1, 100) <= fcChance);

//     if (g_cvDebugMode.BoolValue && isFullControl)
//     {
//         SD_Log("[导演] 路程高压判定成功! (概率: %d%%) -> 激活全控阵容", fcChance);
//     }

//     // [关键修复 1] 计算同类特感的半数限制 (向上取整防止奇数问题)
//     int halfLimit = RoundToCeil(float(maxSI) / 2.0);
//     if (halfLimit < 1) halfLimit = 1;

//     // 2. 填充队列
//     // ---------------------------------------------------------
//     // 分支 A: 全控模式 (无 AOE，全硬控)
//     // ---------------------------------------------------------
//     if (isFullControl)
//     {
//         for (int i = 0; i < slotsNeeded; i++)
//         {
//             // 使用均衡器，防止同类特感满天飞
//             g_hSpawnQueue.Push(SD_PickBalancedPinner(g_cvLimitBatchHalf.BoolValue, halfLimit));
//         }
//     }
//     // ---------------------------------------------------------
//     // 分支 B: 标准模式 (1 AOE + N 硬控)
//     // ---------------------------------------------------------
//     else
//     {
//         // [关键修复 2] 将"活着"、"幽灵"、"排队中"的 AOE 全部算上，彻底杜绝重复！
//         int boomerTotal = SD_CountClass(ZC_BOOMER) + g_iSpawnGhosts[ZC_BOOMER] + SD_CountInQueue(ZC_BOOMER);
//         int spitterTotal = SD_CountClass(ZC_SPITTER) + g_iSpawnGhosts[ZC_SPITTER] + SD_CountInQueue(ZC_SPITTER);

//         // 尝试生成 1 个 AOE (如果三端都没有残留，且有空位)
//         if ((boomerTotal + spitterTotal) == 0 && slotsNeeded > 0)
//         {
//             int aoe = (GetRandomInt(0, 1) == 0) ? ZC_BOOMER : ZC_SPITTER;
//             g_hSpawnQueue.Push(aoe);
//             slotsNeeded--;    // 占用一个名额
//         }

//         // 剩下的位置填满控制特感 (同样使用均衡器)
//         for (int i = 0; i < slotsNeeded; i++)
//         {
//             g_hSpawnQueue.Push(SD_PickBalancedPinner(g_cvLimitBatchHalf.BoolValue, halfLimit));
//         }
//     }

//     // 3. 打乱顺序 (让胖子/口水混在怪堆里发车，给生还者制造混乱)
//     SD_ShuffleQueue(g_hSpawnQueue);
// }

// [核心修改] 生成波次任务 (融入路程概率)
// void SD_GenerateSquadWave()
// {
//     // 1. 获取需要填补的空位
//     int maxSI        = g_cvMaxSI.IntValue;
//     int currentTotal = SD_GetTotalSI_Strict();
//     int slotsNeeded  = maxSI - currentTotal;

//     if (slotsNeeded <= 0) return;

//     // g_hSpawnQueue.Clear(); // 清理旧数据（防御性）

//     // =========================================================
//     // [新逻辑] 路程概率判定：全控阵容 (Full Control)
//     // =========================================================

//     // 获取当前路程对应的全控概率 (0% - 100%)
//     int  fcChance      = GetLogicChance_FullControl();
//     bool isFullControl = (GetRandomInt(1, 100) <= fcChance);

//     // 调试日志
//     if (g_cvDebugMode.BoolValue && isFullControl)
//     {
//         SD_Log("[导演] 路程高压判定成功! (概率: %d%%) -> 激活全控阵容", fcChance);
//     }

//     // 2. 填充队列
//     // ---------------------------------------------------------
//     // 分支 A: 全控模式 (无 AOE，全硬控)
//     // ---------------------------------------------------------
//     if (isFullControl)
//     {
//         for (int i = 0; i < slotsNeeded; i++)
//         {
//             g_hSpawnQueue.Push(SD_PickRandomPinner());    // 只选 Smoker/Hunter/Jockey/Charger
//         }
//     }
//     // ---------------------------------------------------------
//     // 分支 B: 标准模式 (1 AOE + N 硬控)
//     // ---------------------------------------------------------
//     else
//     {
//         // 尝试生成 1 个 AOE (如果场上没有且有空位)
//         if (SD_CountClass(ZC_BOOMER) + SD_CountClass(ZC_SPITTER) == 0 && slotsNeeded > 0)
//         {
//             int aoe = (GetRandomInt(0, 1) == 0) ? ZC_BOOMER : ZC_SPITTER;
//             g_hSpawnQueue.Push(aoe);
//             slotsNeeded--;    // 占用一个名额
//         }

//         // 剩下的位置填满控制特感
//         for (int i = 0; i < slotsNeeded; i++)
//         {
//             g_hSpawnQueue.Push(SD_PickRandomPinner());
//         }
//     }

//     // 3. 打乱顺序 (让胖子/口水混在中间)
//     SD_ShuffleQueue(g_hSpawnQueue);
// }
// // [核心] 生成"1 AOE + N 控制"的爆发队列
// void SD_GenerateSquadWave() {
//     g_hSpawnQueue.Clear(); // 清空旧队列

//     int maxSI = g_cvMaxSI.IntValue;
//     int aoeType = 0;

//     // 1. 决定唯一的 AOE (50% 胖子, 50% 口水)
//     // 如果场上已经有胖子或口水残留，这波就不刷 AOE，全刷控制，防止叠加上限
//     if (SD_CountClass(ZC_BOOMER) + SD_CountClass(ZC_SPITTER) == 0) {
//         aoeType = (GetRandomInt(0, 1) == 0) ? ZC_BOOMER : ZC_SPITTER;
//         g_hSpawnQueue.Push(aoeType);
//     }

//     // 2. 填充剩下的位置 (全部是控制特感)
//     // 现在的队列长度是 1 (或者0)，我们需要填满到 maxSI
//     int slotsNeeded = maxSI - g_hSpawnQueue.Length;

//     for (int i = 0; i < slotsNeeded; i++) {
//         // 只选控制类：Smoker(1), Hunter(3), Jockey(5), Charger(6)
//         // 简单的随机抽选
//         int pick = SD_PickRandomPinner();
//         g_hSpawnQueue.Push(pick);
//     }

//     // 3. [关键] 打乱队列顺序 (Shuffle)
//     // 我们不希望 AOE 总是第一个刷出来，或者总是最后一个。
//     // 打乱后，AOE 混在怪堆里一起冲，压力最大。
//     SD_ShuffleQueue(g_hSpawnQueue);

//     if (g_cvDebugMode.BoolValue) {
//         SD_Log("[波次] 生成突袭小队! 总数: %d (AOE: %s)", maxSI, (aoeType == ZC_BOOMER) ? "胖子" : (aoeType == ZC_SPITTER) ? "口水" : "无");
//     }
// }

// [核心] 生成"1 AOE + N 控制"的爆发队列
// void SD_GenerateSquadWave()
// {
//     g_hSpawnQueue.Clear();    // 清空旧队列

//     int maxSI   = g_cvMaxSI.IntValue;
//     int aoeType = 0;

//     // 1. 决定唯一的 AOE (50% 胖子, 50% 口水)
//     // 如果场上已经有胖子或口水残留，这波就不刷 AOE，全刷控制，防止叠加上限
//     if (SD_CountClass(ZC_BOOMER) + SD_CountClass(ZC_SPITTER) == 0)
//     {
//         aoeType = (GetRandomInt(0, 1) == 0) ? ZC_BOOMER : ZC_SPITTER;
//         g_hSpawnQueue.Push(aoeType);
//     }

//     // 2. 填充剩下的位置 (全部是控制特感)
//     // 现在的队列长度是 1 (或者0)，我们需要填满到 maxSI
//     int slotsNeeded = maxSI - g_hSpawnQueue.Length;
//     int halfLimit   = maxSI >> 1;
//     if (halfLimit < 1) halfLimit = 1;    // 防止除以0或过小

//     for (int i = 0; i < slotsNeeded; i++)
//     {
//         // [修复] 这里传入 halfLimit，而不是 maxSI
//         int pick = SD_PickBalancedPinner(g_cvLimitBatchHalf.BoolValue, halfLimit);
//         g_hSpawnQueue.Push(pick);
//     }
//     // 3. [关键] 打乱队列顺序 (Shuffle)
//     // 我们不希望 AOE 总是第一个刷出来，或者总是最后一个。
//     // 打乱后，AOE 混在怪堆里一起冲，压力最大。
//     SD_ShuffleQueue(g_hSpawnQueue);

//     if (g_cvDebugMode.BoolValue)
//     {
//         SD_Log("[波次] 生成突袭小队! 总数: %d (AOE: %s)", maxSI, (aoeType == ZC_BOOMER) ? "胖子" : (aoeType == ZC_SPITTER) ? "口水"
//                                                                                                                            : "无");
//     }
// }

// 辅助：随机选择一个控制特感
int SD_PickRandomPinner()
{
    // 简单的权重池，你可以根据喜好调整
    // 这里的逻辑是：尽量均摊，或者偏向 Hunter/Jockey
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
        // [优化] 极速判断是否为特感
        if (IsValidInfFast(i))
        {
            if (GetEntProp(i, Prop_Send, "m_zombieClass") == cls) count++;
        }
    }
    return count;
}

// 辅助：洗牌算法 (Fisher-Yates)
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
// =========================================================================
// [新增] 惊喜模式逻辑
// =========================================================================

// 生成全控阵容 (不含胖子/口水)
void SD_GenerateSurpriseWave()
{
    g_hSpawnQueue.Clear();
    int maxSI = g_cvMaxSI.IntValue;

    // 强制填满，全部使用 PickRandomPinner (只选牛/猴/舌/HT)
    for (int i = 0; i < maxSI; i++)
    {
        g_hSpawnQueue.Push(SD_PickRandomPinner());
    }

    SD_ShuffleQueue(g_hSpawnQueue);    // 打乱顺序

    if (g_cvDebugMode.BoolValue)
    {
        SD_Log("[惊喜] 触发！生成 %d 只全控制特感！", maxSI);
    }
}

// 召唤尸潮
// 召唤尸潮 (强制前方)
void SD_TriggerSurpriseMob()
{
    int target = SD_GetRandomSurvivor();
    if (target > 0)
    {
        // 1. 开启强制前方开关
        g_bForceMobFront = true;

        // 2. 设置一个计时器，5秒后自动关闭开关 (防止影响后续的普通尸潮)
        CreateTimer(6.0, Timer_ResetMobForce, _, TIMER_FLAG_NO_MAPCHANGE);

        // 3. 执行尸潮命令
        int flags = GetCommandFlags("z_spawn_old");
        SetCommandFlags("z_spawn_old", flags & ~FCVAR_CHEAT);
        FakeClientCommand(target, "z_spawn_old mob");
        SetCommandFlags("z_spawn_old", flags);

        // PrintToChatAll("\x04[Sion]\x01 ！！！\x03惊喜时刻\x01！！！\x05全控阵容\x01 + \x05正向尸潮\x01！");
    }
}

// [新增] 重置尸潮方向开关
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
// =========================================================================
// [调试] Nav & Bucket 详细信息查看器
// =========================================================================
public Action Cmd_NavDebug(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    // 1. 获取玩家位置
    float pos[3];
    GetClientAbsOrigin(client, pos);

    // 2. 获取最近的 Nav Area
    // 使用 120.0 范围，模拟特感生成的判定宽松度
    Address nav = L4D_GetNearestNavArea(pos, 120.0, false, false, false, TEAM_INFECTED);

    if (nav == Address_Null)
    {
        PrintToChat(client, "\x04[Debug]\x01 当前位置 \x03无法找到 NavArea\x01 (悬空或地图外?)");
        return Plugin_Handled;
    }

    // 3. 获取原生 Nav 数据
    int   id    = L4D_GetNavAreaID(nav);
    int   flags = L4D_GetNavArea_SpawnAttributes(nav);
    float flow  = L4D2Direct_GetTerrorNavAreaFlow(nav);
    float center[3];
    L4D_GetNavAreaCenter(nav, center);

    // 4. 获取插件构建的缓存数据 (分桶信息)
    int   idx    = GetAreaIndexByNavID_Int(id);    // 获取在你 ArrayList 里的索引
    int   bucket = -1;
    float zMin = 0.0, zMax = 0.0, zCore = 0.0;

    // 检查缓存是否有效
    bool  isCached = (idx != -1 && idx < g_AreaPct.Length);
    if (isCached)
    {
        bucket = view_as<int>(g_AreaPct.Get(idx));
        zMin   = view_as<float>(g_AreaZMin.Get(idx));
        zMax   = view_as<float>(g_AreaZMax.Get(idx));
        zCore  = view_as<float>(g_AreaZCore.Get(idx));
    }

    // =========================================================
    // 视觉反馈 (画线：脚底 -> Nav中心)
    // =========================================================
    float visualPos[3];
    visualPos = pos;
    visualPos[2] += 10.0;
    TE_SetupBeamPoints(visualPos, center, PrecacheModel("sprites/laserbeam.vmt"), 0, 0, 0, 5.0, 2.0, 2.0, 10, 0.0, { 255, 0, 0, 255 }, 0);
    TE_SendToAll();

    // =========================================================
    // 控制台详细输出
    // =========================================================
    PrintToConsole(client, "================ [NAV DEBUG] ================");
    PrintToConsole(client, "ID: %d | Index: %d", id, idx);
    PrintToConsole(client, "Pos: %.1f, %.1f, %.1f", center[0], center[1], center[2]);
    PrintToConsole(client, "---------------------------------------------");
    PrintToConsole(client, "[原生数据]");
    PrintToConsole(client, "Flow Dist : %.1f (MapMax: %.1f)", flow, g_fMapMaxFlow);
    PrintToConsole(client, "Flags     : 0x%X", flags);
    Debug_PrintNavFlags(client, flags);    // 解析标志位
    PrintToConsole(client, "---------------------------------------------");
    PrintToConsole(client, "[分桶缓存]");
    if (isCached)
    {
        PrintToConsole(client, "Bucket ID : %d %%", bucket);
        PrintToConsole(client, "Height    : Min=%.1f, Max=%.1f, Core=%.1f", zMin, zMax, zCore);
        PrintToConsole(client, "Player Z  : %.1f (Delta Core: %.1f)", pos[2], pos[2] - zCore);

        // 检查桶是否异常
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

    // =========================================================
    // 聊天框简略输出
    // =========================================================
    PrintToChat(client, "\x04[Debug]\x01 Nav: \x03%d \x01| Flow: \x04%.0f", id, flow);
    if (isCached)
        PrintToChat(client, "\x04[Bucket]\x01 Pct: \x05%d%% \x01| Z-Delta: %.1f", bucket, pos[2] - zCore);
    else
        PrintToChat(client, "\x04[Bucket]\x01 \x02未缓存/无效区域");

    return Plugin_Handled;
}

// 辅助：解析 Nav 标志位并打印 (帮你人肉翻译位掩码)
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
// [调试] Flow 动态显示开关
bool   g_bFlowDebug[MAXPLAYERS + 1];
Handle g_hFlowDebugTimer = null;
// =========================================================================
// [调试] Flow Stream Visualizer (流向可视化)
// =========================================================================
// =========================================================================
// [调试] Flow Stream Visualizer (流向可视化 - 修复版)
// =========================================================================
// =========================================================================
// [调试] Flow Stream Visualizer (动态实时版)
// =========================================================================
public Action Cmd_NavDebugFlow(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    // 切换开关状态
    g_bFlowDebug[client] = !g_bFlowDebug[client];

    if (g_bFlowDebug[client])
    {
        PrintToChat(client, "\x04[Flow]\x01 动态导航已 \x03开启\x01。跟随你的步伐显示前方路径...");

        // 如果计时器没启动，启动它
        if (g_hFlowDebugTimer == null)
        {
            // 0.2秒刷新一次，保证流畅且不卡服
            g_hFlowDebugTimer = CreateTimer(0.2, Timer_FlowDebugThink, _, TIMER_REPEAT);
        }
    }
    else
    {
        PrintToChat(client, "\x04[Flow]\x01 动态导航已 \x04关闭\x01。");

        // 检查还有没有人开着，如果没人开着就关掉计时器省资源
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

// 计时器：负责不断重绘
public Action Timer_FlowDebugThink(Handle timer)
{
    bool anyActive = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        // 只有开启了开关且存活的玩家才绘制
        if (g_bFlowDebug[i] && IsClientInGame(i) && IsPlayerAlive(i))
        {
            DrawFlowPathForClient(i);
            anyActive = true;
        }
        else
        {
            // 如果玩家退了或者死了，自动关闭他的开关
            g_bFlowDebug[i] = false;
        }
    }

    // 如果没人用了，停止计时器
    if (!anyActive)
    {
        g_hFlowDebugTimer = null;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

// 核心绘制逻辑 (每一帧都算)
void DrawFlowPathForClient(int client)
{
    float startPos[3];
    GetClientAbsOrigin(client, startPos);
    startPos[2] += 10.0;

    Address nav = L4D_GetNearestNavArea(startPos, 120.0, false, false, false, TEAM_INFECTED);
    if (nav == Address_Null) return;    // 没踩在 Nav 上就不画

    int idx = GetAreaIndexByNavID_Int(L4D_GetNavAreaID(nav));
    if (idx == -1 || idx >= g_AreaPct.Length) return;

    int   currentBucket = view_as<int>(g_AreaPct.Get(idx));

    // 绘制参数
    float tracePos[3];
    tracePos       = startPos;
    int steps      = 15;    // 向前预测 15 个桶 (稍微短一点保证性能)
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

        // 贪婪寻路
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
            // 颜色动态赋值 (避免编译错误)
            int color[4];
            if (b <= 5)
            {
                color[0] = 255;
                color[1] = 0;
                color[2] = 0;
                color[3] = 255;
            }    // 红
            else if (b <= 10) {
                color[0] = 255;
                color[1] = 128;
                color[2] = 0;
                color[3] = 255;
            }    // 橙
            else {
                color[0] = 0;
                color[1] = 255;
                color[2] = 0;
                color[3] = 255;
            }    // 绿

            // 关键：Life 设置为 0.25 (比计时器间隔 0.2 稍长一点点，保证视觉连续不闪烁)
            TE_SetupBeamPoints(tracePos, center, laserModel, 0, 0, 0, 0.25, 3.0, 3.0, 1, 0.0, color, 0);
            TE_SendToPlayer(client);    // 只发给该玩家看，防止干扰其他人

            tracePos = center;
        }
    }
}

// 辅助函数：发给单个玩家看 (比 SendToAll 省流)
stock void TE_SendToPlayer(int client)
{
    int targets[1];
    targets[0] = client;
    TE_Send(targets, 1);
}
// 辅助：简单的平方距离 (避免开方，提升遍历性能)
stock float GetVectorDistanceSq(const float vec1[3], const float vec2[3])
{
    float dx = vec1[0] - vec2[0];
    float dy = vec1[1] - vec2[1];
    float dz = vec1[2] - vec2[2];
    return (dx * dx + dy * dy + dz * dz);
}
// 在 OnMapStart 或 BuildNavBuckets 之后调用
void BuildLogicCache()
{
    g_bLogicReady = false;

    // 1. 尝试从文件读取 (如果有缓存，直接读，省去计算)
    if (TryLoadLogicFromCache())
    {
        g_bLogicReady = true;
        return;
    }

    // 2. 缓存不存在，开始计算数学曲线
    // SD_Log("[Logic] 正在构建概率曲线表...");

    for (int i = 0; i <= 100; i++)
    {
        float progress = float(i) / 100.0;    // 0.0 -> 1.0

        // === 算法 1: 全控阵容概率 (指数增长) ===
        // 公式: Base + (Max - Base) * (x ^ Exp)
        // 例如 Exp=2.5 时，50%路程时概率依然很低，但80%后会飙升
        float chanceFC = LOGIC_BASE_CHANCE + (LOGIC_MAX_CHANCE - LOGIC_BASE_CHANCE) * Pow(progress, LOGIC_CURVE_EXP);

        // 特殊处理：救援关 (Finale) 的最后阶段 (90%+) 压力拉满
        if (L4D_IsMissionFinalMap() && i > 90) chanceFC = 100.0;

        g_ProbFullControl[i] = RoundToNearest(chanceFC);
        if (g_ProbFullControl[i] > 100) g_ProbFullControl[i] = 100;

        // === 算法 2: 尸潮强制前方概率 (线性增长) ===
        // 前 30% 路程几乎不刷前方尸潮，给玩家热身
        // 后 70% 路程线性增加
        float chanceMob = 0.0;
        if (progress < 0.3)
        {
            chanceMob = 5.0;    // 5% 低保
        }
        else {
            // (progress - 0.3) / 0.7 把剩下的路程映射到 0..1
            float t   = (progress - 0.3) / 0.7;
            chanceMob = 5.0 + 95.0 * t;    // 从 5% 涨到 100%
        }
        g_ProbMobFront[i] = RoundToNearest(chanceMob);
        if (g_ProbMobFront[i] > 100) g_ProbMobFront[i] = 100;
    }

    // 3. 写入文件
    SaveLogicToCache();
    g_bLogicReady = true;
}

// 生成文件路径
void MakeLogicCachePath()
{
    char map[64];
    GetCurrentMap(map, sizeof map);
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof dir, "data/infd_logic");
    if (!DirExists(dir)) CreateDirectory(dir, 511);
    BuildPath(Path_SM, g_sLogicCachePath, sizeof g_sLogicCachePath, "data/infd_logic/%s.kv", map);
}

// 保存到 KV 文件
void SaveLogicToCache()
{
    MakeLogicCachePath();
    KeyValues kv = new KeyValues("LogicCache");
    kv.SetString("map", "");

    // 存入 0-100 每一种进度的概率
    for (int i = 0; i <= 100; i++)
    {
        char key[8];
        IntToString(i, key, sizeof(key));
        kv.JumpToKey(key, true);
        kv.SetNum("fc", g_ProbFullControl[i]);    // Full Control Chance
        kv.SetNum("mf", g_ProbMobFront[i]);       // Mob Front Chance
        kv.GoBack();
    }

    kv.ExportToFile(g_sLogicCachePath);
    delete kv;
}

// 尝试读取
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

    // 读取数据
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
            // 如果文件损坏（缺了某个key），强制重新计算
            delete kv;
            return false;
        }
    }

    delete kv;
    return true;
}

// [万能坐标获取] 寻找生还者前方 distance 距离的任意一个有效路面
// 自动适应所有地图结构（弯道、楼梯、垂直升降）
Address SD_GetForwardNavArea(int client, float distance)
{
    // 1. 获取生还者当前的 Flow 进度
    float currentFlow = L4D2Direct_GetFlowDistance(client);
    float maxFlow     = L4D2Direct_GetMapMaxFlowDistance();

    // 2. 计算目标的 Flow
    // 比如：当前 4000，目标就是 5000
    float targetFlow  = currentFlow + distance;

    // 如果目标超过了地图终点，稍微往回缩一点，防止溢出
    if (targetFlow >= maxFlow) targetFlow = maxFlow - 100.0;
    if (targetFlow < 0.0) return Address_Null;    // 异常情况

    // 3. 将 Flow 转换为桶的百分比 (0-100)
    // 假设 g_fMapMaxFlow 是你在 OnMapStart 里获取的全局最大 Flow
    int targetPercent = RoundToNearest((targetFlow / maxFlow) * 100.0);
    targetPercent     = clampi(targetPercent, 0, 100);

    // 4. 从对应的桶里取点
    // 可能会遇到这个桶是空的（比如这段路正好是断崖），我们允许向后搜 5 个桶
    for (int i = 0; i < 5; i++)
    {
        int p = targetPercent + i;
        if (p > 100) break;

        ArrayList bucket = g_FlowBuckets[p];
        if (bucket != null && bucket.Length > 0)
        {
            // 找到非空桶！随机取一个点
            int areaIdx = bucket.Get(0);    // 取第一个就行，或者随机 GetRandomInt
            return g_AllNavAreasCache.Get(areaIdx);
        }
    }

    return Address_Null;    // 实在找不到（比如到了地图边缘）
}
bool SD_IsForwardBlockedForSurvivors(int client)
{
    if (!IsValidClient(client)) return false;

    float startPos[3];
    GetClientAbsOrigin(client, startPos);

    // 1. 获取起点 Nav (生还者脚下)
    Address navStart = L4D_GetNearestNavArea(startPos, 120.0, false, false, false, TEAM_SURVIVOR);
    if (navStart == Address_Null) return false;

    // 2. [核心] 获取终点 Nav (自动寻找前方 1000 码的位置)
    // 无论地图怎么弯，Flow + 1000 永远是沿路的前方
    Address navGoal = SD_GetForwardNavArea(client, 1000.0);

    if (navGoal == Address_Null)
    {
        // 如果找不到前方的点（可能到终点了），默认路是通的
        return false;
    }

    // 3. 寻路测试
    // 问引擎：能从脚下走到未来那个点吗？
    // 限制代价 2500，如果绕得太远也算不通
    bool isPathClear = L4D2_NavAreaBuildPath(navGoal, navStart, 2500.0, TEAM_SURVIVOR, false);

    return !isPathClear;    // 寻路失败 = 门关着/路断了
}
// 获取当前的特感总数（现状 + 预期）
int SD_GetTotalSI_Strict()
{
    int count = 0;

    // -------------------------------------------------
    // 第一部分：询问引擎“现状”（已经存在的）
    // -------------------------------------------------
    for (int i = 1; i <= MaxClients; i++)
    {
        // 1. 必须在游戏中
        if (!IsClientInGame(i)) continue;

        // 2. 必须是感染者阵营
        if (GetClientTeam(i) != 3) continue;

        // 3. 排除死人 (防止死体占位导致的误判)
        // 注意：如果你使用了"秒踢尸体"逻辑，这里配合 IsPlayerAlive 是双重保险
        if (!IsPlayerAlive(i)) continue;

        // 4. (可选) 排除幽灵状态
        if (IsFakeClient(i) && GetEntProp(i, Prop_Send, "m_isGhost") == 1) continue;

        count++;
    }

    // -------------------------------------------------
    // 第二部分：加上你自己的“预期”（在途的 + 队列里的）
    // -------------------------------------------------

    // 1. 加上还没发货的订单 (队列)
    count += g_hSpawnQueue.Length;

    // 2. [关键] 加上发了货但还没到的订单 (在途)
    // 这个变量是你为了弥补"引擎真空期"而必须手动维护的
    count += g_iTotalPending;

    // 3. 加上已经成型但还没脱离幽灵状态的
    for (int i = 1; i <= 6; i++)
    {
        count += g_iSpawnGhosts[i];
    }

    return count;
}
// [核心工具] 获取当前被占用的总槽位 (存活 + 幽灵 + 队列)
// int SD_GetTotalSI_Strict() {
//     int count = 0;

//     // 1. 场上活着的 (Live)
//     count += SD_GetSICount();

//     // 2. 正在生成的幽灵 (Ghosts) - 还没生出来但已经预定了
//     for(int i=1; i<=8; i++) count += g_iSpawnGhosts[i];

//     // 3. 队列里排队的 (Queue) - 还没轮到处理但已经下达了指令
//     if (g_hSpawnQueue != null) count += g_hSpawnQueue.Length;

//     return count;
// }
// 获取当前进度的“全控”概率
int GetLogicChance_FullControl()
{
    if (!g_bLogicReady) BuildLogicCache();    // 懒加载：如果还没准备好，现在立刻构建

    // 1. 找到跑得最远的生还者
    int bestSurv = GetHighestFlowSurvivorSafe();
    int pct      = 0;

    // 2. 算他的百分比
    if (IsValidSurvFast(bestSurv))
    {
        TryGetClientFlowPercentSafe(bestSurv, pct);
    }

    // 3. 查表返回概率
    return g_ProbFullControl[pct];
}

// 获取当前进度的“前方尸潮”概率
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
    // 0. 安全检查
    if (client == 0)
    {
        ReplyToCommand(client, "[Sion] 控制台无法使用此命令。");
        return Plugin_Handled;
    }

    // 1. [权限检查] 只有最高管理员 或 ROOT 权限可以使用
    // CheckCommandAccess 这里用于判断是否有 root 权限 override
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

    // 获取参数
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    // 查找目标 (支持部分匹配)
    int target = FindTarget(client, arg, true, false);
    if (target == -1) return Plugin_Handled;

    // 获取目标 SteamID
    char auth[64];
    if (!GetClientAuthId(target, AuthId_Steam2, auth, sizeof(auth)))
    {
        ReplyToCommand(client, "\x04[Sion]\x01 错误：无法获取该玩家 SteamID (可能是机器人或未完全连接)。");
        return Plugin_Handled;
    }

    // 2. [反噬保护] 防止把最高管理员自己加进去
    if (StrEqual(auth, SUPER_ADMIN_STEAMID))
    {
        ReplyToCommand(client, "\x04[Sion]\x01 \x02错误：\x01你不能把 \x03最高管理员 (你自己) \x01加入恶搞名单！");
        return Plugin_Handled;
    }

    // 3. 读写逻辑 (写入到内存数组)
    int index = g_hGriefTargets.FindString(auth);

    if (index != -1)
    {
        // --- [移除逻辑] ---
        // 如果已经在名单里，则执行删除
        g_hGriefTargets.Erase(index);

        ReplyToCommand(client, "\x04[Sion]\x01 \x03%N \x01已从名单移除，停止恶搞。", target);
        if (isSuper) PrintToChat(client, "\x04[Sion]\x01 您的宽恕已生效，配置已保存。");
    }
    else
    {
        // --- [添加逻辑] ---
        // 如果不在名单里，则执行添加
        g_hGriefTargets.PushString(auth);

        ReplyToCommand(client, "\x04[Sion]\x01 \x03%N \x01已加入豪华午餐！(贴脸模式开启)", target);
        if (isSuper) PrintToChat(client, "\x04[Sion]\x01 您的意志已执行，目标已写入黑名单文件。");
    }

    // 4. [核心] 立即保存到文件
    // 只要内存变动，立刻刷新文件，确保重启后不丢失
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
            // 简单的格式过滤，忽略空行和注释
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
    // [关键修复] 使用 "w" 模式。
    // 这会清空文件并重写当前内存里的所有名单。
    // 这完美解决了"只能加不能删"的 Bug。
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

// 辅助函数：检查是否为最高管理员
bool IsSuperAdmin(int client)
{
    if (!IsValidClient(client)) return false;
    char auth[64];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))) return false;
    return StrEqual(auth, SUPER_ADMIN_STEAMID);
}
// =========================================================
// [难度系统核心逻辑] (纯净无投票版)
// =========================================================
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

    // ==========================================
    // [关键修复] 状态机重置：清理高档位的残留配置
    // ==========================================
    if (cvCommonLimit != null) cvCommonLimit.SetInt(30);
    if (cvMegaMobSize != null) cvMegaMobSize.SetInt(50);
    if (cvMobSpawnMax != null) cvMobSpawnMax.SetInt(30);

    // 将插件自带的高压控制参数恢复到 CFG 默认值
    g_cvEnableTankControl.RestoreDefault();
    g_cvmobcooldown.RestoreDefault();

    // 第3档及以上：增加小僵尸数量
    if (tier >= 3)
    {
        if (cvCommonLimit != null) cvCommonLimit.SetInt(45);
        if (cvMobSpawnMax != null) cvMobSpawnMax.SetInt(45);
    }

    // 第4档及以上：增加尸潮总持续时间
    if (tier >= 4)
    {
        if (cvMegaMobSize != null) cvMegaMobSize.SetInt(120);
    }

    // 第6档专属：强制锁定极限参数
    if (tier >= 6)
    {
        g_cvEnableTankControl.SetInt(1);
        g_cvmobcooldown.SetFloat(30.0);    // 这里修改了，降档时上面的 RestoreDefault 会负责擦屁股
    }
}
// =========================================================
// [第6档专属] 忍者特感：全局屏蔽特感发声逻辑
// =========================================================
public Action Hook_NormalSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
    // [核心修改] 解耦判断：独立开关开启，或者处于第 6 档时，才进行拦截
    if (!g_cvSilentSI.BoolValue && g_cvDifficultyTier.IntValue < 6)
        return Plugin_Continue;

    if (entity > 0 && entity <= MaxClients && IsClientInGame(entity))
    {
        if (GetClientTeam(entity) == TEAM_INFECTED)
        {
            int zClass = GetEntProp(entity, Prop_Send, "m_zombieClass");
            // 目标分类：Smoker(1), Boomer(2), Hunter(3), Spitter(4), Jockey(5), Charger(6)
            // 排除 Tank(8)，因为 Tank 没声音会导致丢石头没预警，体验极差
            if (zClass >= 1 && zClass <= 6)
            {
                // 暴力屏蔽特感专属音效路径
                if (StrContains(sample, "hunter", false) != -1 || StrContains(sample, "smoker", false) != -1 || StrContains(sample, "boomer", false) != -1 || StrContains(sample, "spitter", false) != -1 || StrContains(sample, "jockey", false) != -1 || StrContains(sample, "charger", false) != -1 || StrContains(sample, "voice", false) != -1)
                {
                    return Plugin_Stop;    // 声音被拦截，静音！
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
    angles[0] = 0.0;    // 锁定水平面，忽略玩家抬头低头

    // 获取玩家的正前/正后向量 (fwd) 以及正左/正右向量 (right)
    GetAngleVectors(angles, fwd, right, NULL_VECTOR);

    // 随机决定这次要放几条声音
    int numSounds = GetRandomInt(1, g_cvPhantomMaxSounds.IntValue);

    for (int i = 0; i < numSounds; i++)
    {
        // 随机分配这个声音的爆发点 (0=正后方, 1=头顶, 2=左侧盲区, 3=右侧盲区, 4=纯随机)
        int dirType = GetRandomInt(0, 4);

        if (dirType == 0)
        {
            // 正后方 200~400 码
            soundPos[0] = origin[0] - (fwd[0] * GetRandomFloat(200.0, 400.0));
            soundPos[1] = origin[1] - (fwd[1] * GetRandomFloat(200.0, 400.0));
            soundPos[2] = origin[2] + 50.0;
        }
        else if (dirType == 1) {
            // 头顶 250~400 码
            soundPos[0] = origin[0] + GetRandomFloat(-100.0, 100.0);
            soundPos[1] = origin[1] + GetRandomFloat(-100.0, 100.0);
            soundPos[2] = origin[2] + GetRandomFloat(250.0, 400.0);
        }
        else if (dirType == 2) {
            // 左侧盲区
            soundPos[0] = origin[0] - (right[0] * GetRandomFloat(200.0, 400.0));
            soundPos[1] = origin[1] - (right[1] * GetRandomFloat(200.0, 400.0));
            soundPos[2] = origin[2] + 50.0;
        }
        else if (dirType == 3) {
            // 右侧盲区
            soundPos[0] = origin[0] + (right[0] * GetRandomFloat(200.0, 400.0));
            soundPos[1] = origin[1] + (right[1] * GetRandomFloat(200.0, 400.0));
            soundPos[2] = origin[2] + 50.0;
        }
        else {
            // 随便找个周围的地方
            soundPos[0] = origin[0] + GetRandomFloat(-300.0, 300.0);
            soundPos[1] = origin[1] + GetRandomFloat(-300.0, 300.0);
            soundPos[2] = origin[2] + GetRandomFloat(50.0, 300.0);
        }

        // 随机抽一个进攻音效
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

        // [关键] 在刚才计算出的坐标引爆这颗“声音炸弹”
        EmitSoundToAll(sound, SOUND_FROM_WORLD, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 1.0, SNDPITCH_NORMAL, -1, soundPos, NULL_VECTOR, true, 0.0);
    }

    if (g_cvDebugMode.BoolValue)
    {
        // 你可以通过看后台日志来欣赏生还者被多少个假声音包围了
        SD_Log("[心理战] 在 %N 四周引爆了 %d 条假进攻音效！", target, numSounds);
    }
}
// 启动定时器的公共入口
void StartPhantomTimer()
{
    // 如果已经有定时器在跑了，先杀掉，防止重复叠加
    if (g_hPhantomTimer != null)
    {
        KillTimer(g_hPhantomTimer);
        g_hPhantomTimer = null;
    }

    float minTime = g_cvPhantomIntervalMin.FloatValue;
    float maxTime = g_cvPhantomIntervalMax.FloatValue;
    if (minTime < 5.0) minTime = 5.0;    // 兜底保护，防止间隔太短导致卡死
    if (maxTime < minTime) maxTime = minTime + 10.0;

    float delay     = GetRandomFloat(minTime, maxTime);
    g_hPhantomTimer = CreateTimer(delay, Timer_PhantomLoop);
}

// 循环定时器本体
public Action Timer_PhantomLoop(Handle timer)
{
    g_hPhantomTimer = null;    // 清空当前句柄

    // 1. 找一个倒霉蛋
    int victim      = SD_GetBestStrategicTarget();
    if (victim <= 0) victim = SD_GetRandomSurvivor();    // 如果没有最佳目标，就随便抽一个存活的

    // 2. 如果有人活着，就播放幻听
    if (victim > 0)
    {
        SD_PlayPhantomSound(victim);    // 调用我们上一回合写好的发声函数
    }

    // 3. 最关键的一步：根据设定的随机范围，再次启动自己！
    float minTime   = g_cvPhantomIntervalMin.FloatValue;
    float maxTime   = g_cvPhantomIntervalMax.FloatValue;
    float nextDelay = GetRandomFloat(minTime, maxTime);

    g_hPhantomTimer = CreateTimer(nextDelay, Timer_PhantomLoop);

    return Plugin_Stop;
}
// [新增] 获取特感当前正在控制的生还者实体索引
int SD_GetSIVictim(int client)
{
    int v = GetEntPropEnt(client, Prop_Send, "m_pummelVictim");    // 牛在砸
    if (v > 0) return v;
    v = GetEntPropEnt(client, Prop_Send, "m_carryVictim");    // 牛在撞
    if (v > 0) return v;
    v = GetEntPropEnt(client, Prop_Send, "m_pounceVictim");    // 猎人在扑
    if (v > 0) return v;
    v = GetEntPropEnt(client, Prop_Send, "m_jockeyVictim");    // 猴子在骑
    if (v > 0) return v;
    v = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");    // 舌头在拉
    if (v > 0) return v;
    return 0;
}
/**
 * Smart Director
 *
 * 根据队伍状态、Nav Flow 和难度配置管理普通特感的配额、队列与生成位置
 * 候选搜索失败时保留引擎生成回退路径，避免队列长期占用在途计数
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <sourcescramble>    // MemoryPatch 与 GameData 接口
#pragma semicolon 1
#pragma newdecls required

// 管理员 SteamID
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

int       g_iTotalPending = 0;    // 已下发但尚未完成生成的特感数量


// 基础校验宏 (编译时直接替换，消除函数调用开销)
#define IsValidClient(%1)   (%1 > 0 && %1 <= MaxClients && IsClientInGame(%1))
#define IsAlive(%1)         (IsPlayerAlive(%1))

// 位掩码用于高频状态判断
// 位掩码由 UpdateClientCache 维护，读取前依赖缓存已同步
#define IsValidSurvFast(%1) (g_iSurvivorMask & (1 << %1))
#define IsValidInfFast(%1)  (g_iInfectedMask & (1 << %1))

static int  g_ProbFullControl[101];    // 全控概率表 (0-100%)
static int  g_ProbMobFront[101];    // 前方尸潮概率表 (0-100%)
static char g_sLogicCachePath[PLATFORM_MAX_PATH] = "";
static bool g_bLogicReady                        = false;

// 基于地图进度的概率曲线参数
#define LOGIC_CURVE_EXP   2.5    // 指数越高，压力越集中在地图后段
#define LOGIC_BASE_CHANCE 5.0    // 地图起点附近的基础触发概率
#define LOGIC_MAX_CHANCE  90.0    // 地图终点附近的最大触发概率

// 特感名称查表数组
char      g_sClassNames[][] = { "Unknown", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger", "Witch", "Tank" };

int       g_iSurvivorMask   = 0;
int       g_iInfectedMask   = 0;    // 存活特感掩码 (不含Tank)
int       g_iSpawnGhosts[10];

// 终点拦截是否已触发
bool      g_bTerminalIntercept = false;
// 上次尸潮触发时间
float     g_fLastMobTime       = 0.0;

// 标记当前生成请求是否由插件发起，供 Hook 判定
bool      g_bIsPluginSpawning  = false;

ConVar    g_cvPhantomMaxSounds;    // 一次最多同时播放几条声音

ConVar    g_cvMaxSI;
ConVar    g_cvSpawnDistMin;
ConVar    g_cvSpawnDistMax;
ConVar    g_cvEnableTankControl;
ConVar    g_cvCullDistance;
ConVar    g_cvDebugMode;
ConVar    g_cvHungerCooldown;    // 补特冷却
ConVar    g_cvLimitBatchHalf;    // 半数限制开关
ConVar    g_cvCheckVis;
ConVar    g_cvmobcooldown;
ConVar    g_cvTankChance;

ConVar    g_cvSilentSI;

// 难度档位与 Tank 尸潮计时器
ConVar    g_cvDifficultyTier;
float     g_fLastTankMobTime = 0.0;
ConVar    g_cvPhantomChance;

Handle    g_hSpawnTimer       = null;
Handle    g_hCacheTimer       = null;
Handle    g_hQueueTimer       = null;
ArrayList g_hSpawnQueue       = null;
bool      g_bTankSpawnedRound = false;
bool      g_bSuperMode        = false;    // 超级模式状态
bool      g_bPanicMode        = false;    // 尸潮或守点阶段状态
float     g_fOriginalMinDist;    // 用于还原距离
float     g_fOriginalMaxDist;    // 用于还原距离
Handle    g_hPanicEndTimer  = null;    // 用于自动结束尸潮状态

float     g_fNextTankTime   = 0.0;
float     g_fLastSupplyTime = 0.0;    // 上次补充特感的时间
bool      g_bLateLoad       = false;
bool      g_bLeftSafeArea   = false;
float     fPathCacheQuantize;

float     g_fFlowCache[MAXPLAYERS + 1];
float     g_fLastMaxFlow = 0.0;
float     g_vLastFlowPos[MAXPLAYERS + 1][3];
bool      g_bIsPinned[MAXPLAYERS + 1];
bool      g_bIsIncap[MAXPLAYERS + 1];
bool      g_bIsBiled[MAXPLAYERS + 1];
float     g_fSpawnTime[MAXPLAYERS + 1];

bool      g_bForceMobFront = false;    // 是否强制尸潮从队伍前方生成

bool      g_bUserOverride_TankControl = false;    // 记录用户是否覆盖 Tank 控制
bool      g_bUserOverride_MobCD       = false;    // 记录用户是否覆盖尸潮冷却
int       g_iUserVal_TankControl      = 1;    // 用户覆盖的 Tank 控制值
float     g_fUserVal_MobCD            = 60.0;    // 用户覆盖的尸潮冷却

int       g_iCachedTeam[MAXPLAYERS + 1];
bool      g_bCachedAlive[MAXPLAYERS + 1];
bool      g_bCachedInGame[MAXPLAYERS + 1];

ConVar    g_cvPhantomIntervalMin;
ConVar    g_cvPhantomIntervalMax;
Handle    g_hPhantomTimer = null;


#define FLOW_BUCKETS     101    // 0..100
#define BUCKET_CACHE_VER "2026.2.10"    // 和插件版号保持同步

static ArrayList g_AllNavAreasCache   = null;
static int       g_NavAreasCacheCount = 0;
static ArrayList g_AreaZCore          = null;
static ArrayList g_AreaZMin           = null;
static ArrayList g_AreaZMax           = null;
static float     g_BucketMinZ[FLOW_BUCKETS];
static float     g_BucketMaxZ[FLOW_BUCKETS];

static StringMap g_NavIdToIndex                        = null;
static char      g_sBucketCachePath[PLATFORM_MAX_PATH] = "";
static int       g_LastGoodSurPct                      = -1;    // 0..100
static float     g_LastGoodSurPctTime                  = 0.0;

static ArrayList g_FlowBuckets[FLOW_BUCKETS];
static bool      g_BucketsReady = false;

static ArrayList g_AreaCX       = null;
static ArrayList g_AreaCY       = null;
static ArrayList g_AreaPct      = null;

float            fNavBucketAssignRadius;    // 异常 Flow 区域就近归桶的最大搜索距离；0 表示不限制
bool             bNavCacheEnable;
ConVar           VsBossFlowBuffer;
bool             bNavBucketMapInvalid;
int              iSiLimit;
#define SEP_TTL            3.0    // 最近生成点记录的保留时间
#define SEP_RADIUS         80.0
#define PEN_LIMIT_SCALE_HI 1.00    // 低特感上限时保留完整惩罚
#define PEN_LIMIT_SCALE_LO 0.50    // 高特感上限时减弱位置惩罚
#define PEN_LIMIT_MINL     1
#define PEN_LIMIT_MAXL     16

ArrayList lastSpawns = null;


bool      bSurFlowFallback;
float     fSurFlowFallbackTTL;

float     g_fMapMaxFlow = 0.0;    // 地图最大 Flow 距离（用于归一化百分比）
methodmap TheNavAreas
{
    // 通过 Left4DHooks 获取全部 NavArea
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

    // 通过 Left4DHooks 在 NavArea 内采样随机点
public     void GetRandomPoint(float outPos[3])
    {
        L4D_FindRandomSpot(view_as<int>(this), outPos);
    }

    // 通过 Left4DHooks 读取和设置 SpawnAttributes
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

    // 通过 Left4DHooks 读取 Nav Flow
public     float GetFlow()
    {
        return L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(this));
    }
}

// L4D2 NavArea 标志位 （参考 wiki / fdxx）
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
static StringMap g_PathCacheRes = null;    // key -> int(0/1)

bool bPathCacheEnable;


public Plugin myinfo =
{
    name        = "Smart Director",
    author      = "Sion Gemini",
    description = "Native NNUE candidate ranking + Nav validation",
    version     = "23.0-beta1",
    url         = "https://steamcommunity.com/profiles/76561199209427576"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_bLateLoad = late;
    SDNNUE_MarkNativesOptional();
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
    // 参数 1：1 开启，0 关闭
    bool enable = view_as<bool>(GetNativeCell(1));

    // 仅在状态发生变化时更新配置
    if (g_bSuperMode != enable)
    {
        g_bSuperMode = enable;

        if (enable)
        {
            // 超级模式将特感上限提高到 24
            g_cvMaxSI.SetInt(24);
            PrintToChatAll("\x04[Sion]\x01 外部指令：已激活 \x03[超多特模式] \x01(上限自动锁定: \x0324\x01)");
            PrintToChatAll("\x04[配置]\x01 严格限制：25%%牛 20%%HT 20%%猴 15%%舌");
        }
        else {
            // 关闭超级模式后恢复默认特感上限
            // 默认恢复为 8
            g_cvMaxSI.SetInt(8);
            PrintToChatAll("\x04[Sion]\x01 外部指令：已关闭超多特模式 \x01(上限恢复: \x038\x01)");
        }

        UnlockLimits();    // 同步更新引擎侧特感上限
    }
    return 1;
}

// 设置处死距离 API
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
    // 冷却下限为 1 秒，避免过高调用频率
    if (cooldown < 1.0) cooldown = 0.1;

    g_cvHungerCooldown.SetFloat(cooldown);
    // 用户修改冷却时同步记录尸潮冷却覆盖
    g_bUserOverride_MobCD = true;
    g_fUserVal_MobCD      = cooldown;
    PrintToChatAll("\x04[Sion]\x01 外部指令: 补货冷却已更新为 \x03%.1f秒", cooldown);
    return 1;
}

public int Native_SetTankControl(Handle plugin, int numParams)
{
    bool enable = view_as<bool>(GetNativeCell(1));
    g_cvEnableTankControl.SetInt(enable ? 1 : 0);
    // 记录用户覆盖，跨关保持
    g_bUserOverride_TankControl = true;
    g_iUserVal_TankControl = enable ? 1 : 0;
    if (!enable) PrintToChatAll("\x04[Sion]\x01 外部指令: Tank生成已切换为 \x03[原生导演]");
    else PrintToChatAll("\x04[Sion]\x01 外部指令: Tank生成已切换为 \x03[插件接管]");
    return 1;
}

public int Native_SetMaxSpecials(Handle plugin, int numParams)
{
    int amount = GetNativeCell(1);
    if (amount < 0) amount = 0;
    if (amount > 32) amount = 32;

    g_cvMaxSI.SetInt(amount);    // 更新插件配置
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
// Nav Flow 分桶基础参考 CompetitiveWithAnne 历史版本 d68cca7ad2465539a3bf4105aa34aebab9c7f633
// addons/sourcemod/scripting/AnneHappy/infected_control.sp (v2025.10.26)
static void BuildNavBuckets()
{
    g_fMapMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    // 尝试读缓存（成功就直接返回）
    if (TryLoadBucketsFromCache())
        return;

    // 清理旧数据、准备索引与缓存
    ClearNavBuckets();
    BuildNavIdIndexMap();
    EnsureNavAreasCache();

    int   iAreaCount      = g_NavAreasCacheCount;
    float fMapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();

    // 初始化 per-area / per-bucket 容器
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
        g_AreaPct.Push(-1);    // -1 表示该区域尚未获得有效 Flow
    }

    for (int b = 0; b < FLOW_BUCKETS; b++)
    {
        g_FlowBuckets[b] = null;
        g_BucketMinZ[b]  = 1.0e9;
        g_BucketMaxZ[b]  = -1.0e9;
    }

    ArrayList badIdxs   = new ArrayList();
    ArrayList validIdxs = new ArrayList();

    // 第一遍：采样中心/高度，正常 flow 直接入桶
    for (int i = 0; i < iAreaCount; i++)
    {
        Address areaAddr = g_AllNavAreasCache.Get(i);
        if (areaAddr == Address_Null) continue;

        NavArea pArea = view_as<NavArea>(areaAddr);

        // // 过滤不合规的 Nav flags（救援/安全屋等）

        // 最多采样 3 次估计区域中心高度
        float   cx, cy, zAvg, zMin, zMax;
        SampleAreaCenterAndZ(areaAddr, cx, cy, zAvg, zMin, zMax, 3);
        g_AreaCX.Set(i, cx);
        g_AreaCY.Set(i, cy);
        g_AreaZCore.Set(i, zAvg);
        g_AreaZMin.Set(i, zMin);
        g_AreaZMax.Set(i, zMax);

        // 有效 Flow 直接映射到百分比桶；异常值进入待修复列表
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

    // 第二遍：把坏 flow 的区域映射到最近“有效桶”（二维栅格 + 成本/时间保护）
    if (validIdxs.Length > 0 && badIdxs.Length > 0)
    {
        // 1 估算成本与时间预算
        int         B = badIdxs.Length, V = validIdxs.Length;
        float       estCostM    = float(B) * float(V) / 1.0e6;
        const float hardCostM   = 5.0;    // 预计超过约 500 万次配对时跳过映射
        const float timeBudgetS = 0.60;    // 映射总耗时超过 0.6 秒时提前停止

        float       t1          = GetEngineTime();
        if (estCostM > hardCostM)
        {
            // Debug_Print("[BUCKET] pass2 SKIP(cost): B=%d V=%d est≈%.1fM", B, V, estCostM);
        }
        else
        {
            // 2 构建“有效区”二维栅格
            const float cell   = 2000.0;    // 二维栅格边长
            float       radius = fNavBucketAssignRadius;    // 0 表示不限制搜索半径
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

            // 3 邻格扩环检索参数
            int maxLayer = (radius > 0.1) ? RoundToCeil(radius / cell) : 6;
            if (maxLayer < 0) maxLayer = 0;
            if (maxLayer > 48) maxLayer = 48;
            float r2     = (radius > 0.1) ? (radius * radius) : -1.0;

            int   mapped = 0, dropped = 0;

            // 4 对每个坏区做邻格扩环搜索
            for (int bi = 0; bi < B; bi++)
            {
                // 每处理 1024 个区域检查一次时间预算
                if ((bi & 1023) == 0)
                {
                    float el = GetEngineTime() - t1;
                    if (el > timeBudgetS)
                    {
                        // Debug_Print("[BUCKET] pass2 ABORT(time): bi=%d/%d mapped=%d dropped=%d el=%.3fs",
                        // bi, B, mapped, dropped, el);
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

                // 每层只扫描外环，避免重复遍历内部栅格
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

            // Debug_Print("[BUCKET] pass2 %s: B=%d V=%d mapped=%d dropped=%d took=%.3fs",
            // aborted ? "done(partial)" : "done",
            // B, V, mapped, dropped, GetEngineTime() - t1);

            // 5 释放 cellMap 内存
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
        // gCV.bNavBucketMapInvalid ? 1 : 0, validIdxs.Length, badIdxs.Length);
    }

    // 完成：标记就绪 & 存缓存
    g_BucketsReady = true;
    // Debug_Print("[BUCKET] build done: took=%.3fs", GetEngineTime() - t0);

    SaveBucketsToCache();    // 启用缓存时写入 `.kv` 文件
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

    // 每个 Flow 桶的高度范围
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

    // 将 Flow 距离钳位到有效地图范围
    float d = flowDist;
    if (!(d >= 0.0)) d = 0.0;    // 无效负值按 0 处理
    if (d > maxd) d = maxd;    // 限制到地图最大 Flow 距离

    // Boss Flow Buffer 按距离叠加
    float prox = d + VsBossFlowBuffer.FloatValue;
    if (!(prox >= 0.0)) prox = 0.0;
    if (prox > maxd) prox = maxd;

    return RoundToNearest((prox / maxd) * 100.0);    // 转换为 0..100 的进度百分比
}

// 通过随机采样估计 NavArea 中心与高度范围
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

    // 运行参数变化时使缓存失效
    float bufCur        = VsBossFlowBuffer.FloatValue;
    float bufCached     = kv.GetFloat("vsboss_buffer", 0.0);
    int   mapInvalidCur = bNavBucketMapInvalid ? 1 : 0;
    int   mapInvalidCac = kv.GetNum("map_invalid", 1);
    float assignRcur    = fNavBucketAssignRadius;
    float assignRcac    = kv.GetFloat("assign_radius", 0.0);

    // 去掉 stuck_probe 的一致性校验
    if (FloatAbs(bufCur - bufCached) > 0.01 || mapInvalidCur != mapInvalidCac || FloatAbs(assignRcur - assignRcac) > 0.5)
    {
        delete kv;
        return false;
    }

    // 重置并初始化分桶容器
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

    // 每个 Flow 桶的高度范围
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
// 返回存活生还者的最低脚底高度
static void OnFlowBufferChanged(ConVar convar, const char[] ov, const char[] nv)
{
    // Boss Flow Buffer 变化后重新构建分桶
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

// 安全读取玩家 Flow 距离
// 直接读玩家 flow；异常 → 2) 用 L4D_GetLastKnownArea(client) 取 Nav flow；仍异常 → 3) 最近 NavArea
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
// 将安全 Flow 距离转换为百分比
bool TryGetClientFlowPercentSafe(int client, int &outPct)
{
    float d;
    if (!TryGetClientFlowDistanceSafe(client, d)) return false;
    outPct = FlowDistanceToPercent(d);
    if (outPct < 0) outPct = 0;
    if (outPct > 100) outPct = 100;
    return true;
}

#include "include/sd_nnue_bridge.inc"
// 返回有效 Flow 最大的生还者
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
    // 全部安全读取失败时回退到引擎原生接口
    return L4D_GetHighestFlowSurvivor();
}
// 统计可参与战斗的生还者

// 根据可行动生还者数量调整补充冷却
// `sd_hunger_cooldown` 为四人存活时的基准冷却
static float SD_GetDynamicCooldown()
{
    float baseCooldown = g_cvHungerCooldown.FloatValue;

    // 倒地生还者不计入可行动人数
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
    // 1 人：30% 基准冷却
    float scale;
    switch (alive)
    {
        case 0: scale = 0.30;    // 0 人时沿用最低冷却比例
        case 1: scale = 0.30;
        case 2: scale = 0.50;
        case 3: scale = 0.70;
        default: scale = 1.00;
    }

    float result = baseCooldown * scale;
    return result;
}

// --- Math helpers ---
stock int clampi(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}
/**
 * 构造 Nav Flow 桶的扫描顺序
 *
 * 顺序从中心桶向两侧展开，初始采用“前 2、后 1”的批次
 * 当实际加入的前方桶比后方桶多 4 个以上时，同时扩大两侧批次，
 * 保留原有的前向偏置，同时避免长期只搜索单侧
 */
static int BuildBucketOrder(int s, int win, bool includeCenter, int outBuckets[FLOW_BUCKETS])
{
    s   = clampi(s, 0, 100);
    win = clampi(win, 0, 100);

    int n = 0;
    if (includeCenter)
        outBuckets[n++] = s;

    // 预先裁掉必然越界的偏移，避免在地图两端执行无效循环
    int maxForward  = (win < 100 - s) ? win : 100 - s;
    int maxBackward = (win < s) ? win : s;

    int forwardDist  = 1;
    int backwardDist = 1;
    int forwardRun   = 2;
    int backwardRun  = 1;
    int addedForward = 0;
    int addedBack    = 0;

    while ((forwardDist <= maxForward || backwardDist <= maxBackward) && n < FLOW_BUCKETS)
    {
        int forwardCount = 0;
        if (forwardDist <= maxForward)
        {
            forwardCount = maxForward - forwardDist + 1;
            if (forwardCount > forwardRun)
                forwardCount = forwardRun;

            for (int i = 0; i < forwardCount && n < FLOW_BUCKETS; i++)
                outBuckets[n++] = s + forwardDist++;

            addedForward += forwardCount;
        }

        int backwardCount = 0;
        if (backwardDist <= maxBackward)
        {
            backwardCount = maxBackward - backwardDist + 1;
            if (backwardCount > backwardRun)
                backwardCount = backwardRun;

            for (int i = 0; i < backwardCount && n < FLOW_BUCKETS; i++)
                outBuckets[n++] = s - backwardDist++;

            addedBack += backwardCount;
        }

        if (addedForward - addedBack > 4)
        {
            forwardRun++;
            backwardRun++;
        }
    }

    return n;
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
    // 将特感上限钳位到惩罚缩放区间
    float L = float(iSiLimit);
    float t = Clamp01((L - float(PEN_LIMIT_MINL)) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL));
    // 特感上限越高，位置惩罚逐步减弱
    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}

stock bool PassMinSeparation(const float pos[3])
{
    if (lastSpawns == null || lastSpawns.Length == 0) return true;

    float now            = GetGameTime();
    float k              = PenLimitScale();    // 00 → 0.50 (随上限增大而变小)
    float SEP_RADIUS_EFF = SEP_RADIUS * k;    // 惩罚减弱时允许候选点更接近
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

        // 距离计算只使用坐标分量
        float rec3[3];
        rec3[0] = rec[0];
        rec3[1] = rec[1];
        rec3[2] = rec[2];

        // 使用平方距离比较，避免开方
        if (GetVectorDistance(pos, rec3, true) < sep2)
            return false;
    }
    return true;
}

// 读取未过期的生还者进度回退值
static bool GetFallbackSurPct(int &outPct)
{
    if (!bSurFlowFallback) return false;
    if (g_LastGoodSurPct < 0) return false;
    float now = GetGameTime();
    if ((now - g_LastGoodSurPctTime) > fSurFlowFallbackTTL) return false;
    outPct = g_LastGoodSurPct;
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
    // 基础过滤
    if (entity <= MaxClients) return false;    // 玩家不参与 Hull 阻挡判断
    if (!IsValidEntity(entity)) return false;

    // 仅对必要实体读取 classname
    // 普通感染者和 Witch 不作为生成碰撞阻挡
    // 只执行生成碰撞所需的最小类别判断


    // 先检查 classname 前缀，再决定是否忽略实体
    static char cls[16];
    GetEntityClassname(entity, cls, sizeof(cls));

    // `infected` 前缀为 `in`
    // `witch` 前缀为 `wi`
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
static void InitSDK_FromGamedata()
{
    char sBuffer[128];

    strcopy(sBuffer, sizeof(sBuffer), "function_data");
    GameData hGameData = new GameData(sBuffer);
    if (hGameData == null)
        SetFailState("Failed to load \"%s.txt\" gamedata.", sBuffer);

    // 仅保留解除最大特感数量限制所需的 MemoryPatch
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

    // 死亡的特感 Bot 延迟释放客户端槽位
    if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == 3 && IsFakeClient(client))
    {
        // 死亡后短暂延迟踢出，避免槽位统计滞后
        // 延迟 0.1 秒释放死亡 Bot 槽位
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
    SDNNUE_CreateConVars();
    g_hSpawnQueue   = new ArrayList();
    InitSDK_FromGamedata();    // ← 加载 NavArea SDK/偏移
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
    g_cvSilentSI           = CreateConVar("sd_silent_si", "0", "独立选项: 是否开启无声特感 (全局屏蔽特感叫声): 0=关, 1=开");
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
    // 初始化指定目标列表
    g_hGriefTargets = new ArrayList(ByteCountToCells(64));    // ArrayList 按字符串所需 cell 数分配
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
    HookEvent("player_death", Event_PlayerDeath_Kick, EventHookMode_Pre);    // 在 Pre 阶段处理死亡事件，尽早释放计数

    HookEvent("player_team", Event_CacheUpdate);
    HookEvent("player_spawn", Event_CacheUpdate_Spawn);
    HookEvent("player_death", Event_CacheUpdate);
    HookEvent("player_disconnect", Event_CacheUpdate_Disconnect);

    RegAdminCmd("sm_sd_force_spawn", Cmd_ForceSpawn, ADMFLAG_ROOT, "强制生成");
    RegAdminCmd("sm_sd_force_tank", Cmd_ForceTank, ADMFLAG_ROOT, "强制Tank封路测试");
    RegAdminCmd("sm_sd_rebuild_nav", Cmd_RebuildNav, ADMFLAG_ROOT, "强制重建Nav分桶");

    PrecacheSound("player/hunter/voice/attack/hunter_shriek_1.wav");    // Hunter 飞扑尖叫
    PrecacheSound("player/boomer/voice/attack/boomer_attack_01.wav");    // Boomer 吐胆汁的瞬间
    PrecacheSound("player/smoker/voice/attack/smoker_attack_01.wav");    // Smoker 吐舌头
    PrecacheSound("player/jockey/voice/attack/jockey_attack_01.wav");    // Jockey 起跳怪叫
    PrecacheSound("player/charger/voice/attack/charger_charge_01.wav");    // Charger 冲锋怒吼

    SDNNUE_RefreshRuntime();
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
    // 记录原始距离（如果是第一次触发，防止重复覆盖）
    if (!g_bPanicMode)
    {
        g_fOriginalMinDist = g_cvSpawnDistMin.FloatValue;
        g_fOriginalMaxDist = g_cvSpawnDistMax.FloatValue;
    }
    // 激活高压模式
    g_bPanicMode = true;

    // 压缩生成距离 (让特感贴脸刷，比如 100~500)
    // 守点阶段优先提高近距离威胁
    g_cvSpawnDistMin.SetFloat(100.0);
    g_cvSpawnDistMax.SetFloat(600.0);
    UnlockLimits();    // 应用到引擎

    PrintToChatAll("\x04[Sion]\x01 : \x03尸潮爆发！\x01特感距离已压缩，AOE配额提升！");

    // 设置复位定时器
    // 缺少稳定的尸潮结束事件，因此使用保守超时复位
    if (g_hPanicEndTimer != null) KillTimer(g_hPanicEndTimer);
    g_hPanicEndTimer = CreateTimer(10.0, Timer_EndPanicMode);

    return Plugin_Continue;
}

// 恢复尸潮前的生成参数
public Action Timer_EndPanicMode(Handle timer)
{
    g_bPanicMode     = false;
    g_hPanicEndTimer = null;

    g_cvSpawnDistMin.SetFloat(g_fOriginalMinDist);
    g_cvSpawnDistMax.SetFloat(g_fOriginalMaxDist);
    UnlockLimits();

    PrintToChatAll("\x04[Sion]\x01 : 尸潮消退，生成逻辑恢复正常");
    return Plugin_Stop;
}

public void OnMapStart()
{
    LockLimits();
    ApplyOptimizations();
    CreateTimer(1.0, Timer_BuildNavBuckets_Delayed);
    BuildLogicCache();
    SD_ApplyTierSettings(g_cvDifficultyTier.IntValue);
    SDNNUE_RefreshRuntime();
}

public void OnMapEnd()
{
    ClearNavBuckets();
    // 清理基础 Nav 缓存 (NavAreas)
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

    // 模式 1：仅检查目标生还者可见性
    if (mode == 1 && IsValidClient(target))
    {
        if (L4D2_IsVisibleToPlayer(target, TEAM_SURVIVOR, TEAM_INFECTED, 0, checkPos)) return true;
        return false;
    }

    // 模式 2：检查全部存活生还者可见性
    for (int i = 1; i <= MaxClients; i++)
    {
        // 通过生还者位掩码筛选有效客户端
        if (IsValidSurvFast(i))
        {
            if (L4D2_IsVisibleToPlayer(i, TEAM_SURVIVOR, TEAM_INFECTED, 0, checkPos)) return true;
        }
    }
    return false;
}
bool SD_FindNavSpawnPos_Advanced(int targetClient, float minRange, float maxRange, bool reqVis, float outPos[3])
{
    if (!g_BucketsReady) return false;
    float targetPos[3];
    GetClientAbsOrigin(targetClient, targetPos);

    int targetPercent = 0;
    // 使用安全的获取方式纠正断层进度
    if (!TryGetClientFlowPercentSafe(targetClient, targetPercent))
    {
        // 如果彻底断层，使用回退进度兜底
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

            // 强制立体包围 (反扎堆检测)
            if (!PassMinSeparation(p)) continue;

            // 动态计算寻路极限：直线距离的 1.5 倍 + Z轴高度差的 2.5 倍
            float zDiff     = FloatAbs(p[2] - targetPos[2]);
            float pathLimit = (dist * 1.5) + (zDiff * 2.5);

            // 调用 Nav 候选位置搜索
            if (PathPenalty_NoBuild(p, targetClient, pathLimit) != 0.0)
                continue;

            outPos = p;

            // 记录成功点位，供同批次的下一个特感避开此区域
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

/**
 * 记录真正完成生成的 NNUE 点位。
 * 只有 L4D2_SpawnSpecial 成功后才写入，避免失败候选污染短时分散约束。
 */
static void SDNNUE_RecordAcceptedSpawnPos(const float pos[3])
{
    float record[4];
    record[0] = pos[0];
    record[1] = pos[1];
    record[2] = pos[2];
    record[3] = GetGameTime();

    if (lastSpawns == null) lastSpawns = new ArrayList(4);
    lastSpawns.PushArray(record);
}

/**
 * NNUE 前只保留纯几何和低成本过滤。
 * Hull、LOS 和 Nav path 都延迟到排序后，仅对高分候选调用一次引擎检查。
 */
static float g_fSDNNUECandidateDist[SDNNUE_MAX_CANDIDATES];
static float g_fSDNNUECandidateHeightDiff[SDNNUE_MAX_CANDIDATES];

static bool SDNNUE_TryBuildCheapCandidate(int areaIdx,
                                          const float targetPos[3],
                                          float minRange,
                                          float maxRange,
                                          float outPos[3],
                                          float &outDist)
{
    if (areaIdx < 0 || areaIdx >= g_NavAreasCacheCount) return false;

    Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
    if (areaAddr == Address_Null) return false;

    NavArea area = view_as<NavArea>(areaAddr);
    area.GetRandomPoint(outPos);

    outDist = GetVectorDistance(targetPos, outPos);
    float slack = (outPos[2] > targetPos[2] + 100.0) ? 150.0 : 0.0;
    if (outDist < minRange || outDist > (maxRange + slack)) return false;

    // 分散约束只做平方距离比较，适合在 NNUE 前提前过滤。
    if (!PassMinSeparation(outPos)) return false;
    return true;
}

/**
 * 从 Flow buckets 收集几何上可行的候选并一次性编码为 NNUE bitset。
 * 每个桶采用随机起点 + 均匀步进采样，避免同一批次反复抽到同一个 NavArea。
 * visibility bit 在候选阶段保持未知，避免为全部候选支付 LOS 查询成本。
 */
static int SDNNUE_CollectCandidates(int zClass,
                                    int targetClient,
                                    float minRange,
                                    float maxRange)
{
    if (!g_BucketsReady || !SDNNUE_IsOperationalForClass(zClass)) return 0;

    float targetPos[3];
    GetClientAbsOrigin(targetClient, targetPos);

    int targetPercent = 0;
    if (!TryGetClientFlowPercentSafe(targetClient, targetPercent))
    {
        int fallbackPercent;
        if (GetFallbackSurPct(fallbackPercent))
            targetPercent = fallbackPercent;
    }

    SDNNUE_BuildSharedFeatures();
    SDNNUE_ResetCandidates();

    int leaderPercent = SDNNUE_GetLeaderPercent();
    int maxCandidates = g_cvNNUE_MaxCandidates.IntValue;
    if (maxCandidates < 1) maxCandidates = 1;
    if (maxCandidates > SDNNUE_MAX_CANDIDATES) maxCandidates = SDNNUE_MAX_CANDIDATES;

    int samplesPerBucket = g_cvNNUE_SamplesPerBucket.IntValue;
    if (samplesPerBucket < 1) samplesPerBucket = 1;

    int searchBuckets[FLOW_BUCKETS];
    int bucketCount = BuildBucketOrder(targetPercent, 25, true, searchBuckets);

    for (int i = 0; i < bucketCount && g_iNNUECandidateCount < maxCandidates; i++)
    {
        int bucketIndex = searchBuckets[i];

        // Bucket 高度范围是预计算的粗过滤，避免进入不可能的垂直区域。
        if (g_BucketMaxZ[bucketIndex] < targetPos[2] - 500.0
            || g_BucketMinZ[bucketIndex] > targetPos[2] + 500.0)
            continue;

        ArrayList bucket = g_FlowBuckets[bucketIndex];
        if (bucket == null || bucket.Length == 0) continue;

        int count = bucket.Length;
        int attempts = count;
        if (attempts > samplesPerBucket) attempts = samplesPerBucket;
        if (attempts <= 0) continue;

        int start = GetRandomInt(0, count - 1);
        for (int k = 0; k < attempts && g_iNNUECandidateCount < maxCandidates; k++)
        {
            // floor(k * count / attempts) 单调递增，因此 attempts<=count 时不会重复 area slot。
            int offset = (start + (k * count) / attempts) % count;
            int areaIdx = bucket.Get(offset);

            float candidate[3];
            float dist;
            if (!SDNNUE_TryBuildCheapCandidate(
                    areaIdx,
                    targetPos,
                    minRange,
                    maxRange,
                    candidate,
                    dist))
                continue;

            float heightDiff = candidate[2] - targetPos[2];
            int row = SDNNUE_AddCandidate(
                candidate,
                zClass,
                dist,
                heightDiff,
                bucketIndex,
                leaderPercent,
                -1);

            if (row >= 0)
            {
                // 排序后直接复用，避免再次获取目标位置和计算距离。
                g_fSDNNUECandidateDist[row] = dist;
                g_fSDNNUECandidateHeightDiff[row] = heightDiff;
            }
        }
    }

    return g_iNNUECandidateCount;
}

/**
 * 普通特感的 NNUE 主路径：
 * cheap geometry -> batch NNUE -> Hull/LOS/Nav once -> spawn。
 * 引擎合法性检查只对高分候选执行，NNUE 不能绕过最终碰撞、视线或 Nav 可达性。
 */
static bool SDNNUE_TrySpawnRanked(int zClass,
                                  int targetClient,
                                  float minRange,
                                  float maxRange,
                                  bool reqVis)
{
    int count = SDNNUE_CollectCandidates(zClass, targetClient, minRange, maxRange);
    if (count <= 0) return false;

    if (SDNNUE_ScoreCandidates() != count) return false;

    bool tried[SDNNUE_MAX_CANDIDATES];
    for (int i = 0; i < count; i++) tried[i] = false;

    int maxPathChecks = g_cvNNUE_MaxPathChecks.IntValue;
    if (maxPathChecks < 1) maxPathChecks = 1;
    if (maxPathChecks > count) maxPathChecks = count;

    int pathChecks = 0;
    int finalRejects = 0;

    for (int rank = 0; rank < count && pathChecks < maxPathChecks; rank++)
    {
        int idx = SDNNUE_ArgMaxUntried(tried, count);
        if (idx < 0) break;
        tried[idx] = true;

        float candidate[3];
        candidate[0] = g_fNNUECandidatePos[idx][0];
        candidate[1] = g_fNNUECandidatePos[idx][1];
        candidate[2] = g_fNNUECandidatePos[idx][2];

        // 引擎查询只在 NNUE 排序后执行一次，避免对整批候选重复 Trace/LOS。
        if (WillStuck(candidate))
        {
            finalRejects++;
            continue;
        }
        if (reqVis && SD_IsPosVisible(candidate, targetClient))
        {
            finalRejects++;
            continue;
        }

        float finalPathLimit = (g_fSDNNUECandidateDist[idx] * 1.5)
                             + (FloatAbs(g_fSDNNUECandidateHeightDiff[idx]) * 2.5);
        pathChecks++;
        if (PathPenalty_NoBuild(candidate, targetClient, finalPathLimit) != 0.0)
            continue;

        float selectedScore = g_fNNUEScores[idx];
        if (!SD_ExecuteSpawn(zClass, targetClient, candidate))
            continue;

        SDNNUE_RecordAcceptedSpawnPos(candidate);

        if (g_cvNNUE_Debug.BoolValue)
        {
            int cacheHits = 0;
            int cacheMisses = 0;
            int dedupHits = 0;
            int batches = 0;
            float lastMs = 0.0;
            SDNNUE_GetStats(cacheHits, cacheMisses, dedupHits, batches, lastMs);
            PrintToServer(
                "[SD-NNUE] spawned class=%d candidates=%d rank=%d score=%.5f pathChecks=%d finalRejects=%d infer=%.4fms cache=%d/%d dedup=%d",
                zClass, count, rank + 1, selectedScore, pathChecks, finalRejects,
                lastMs, cacheHits, cacheMisses, dedupHits);
        }

        return true;
    }

    if (g_cvNNUE_Debug.BoolValue)
    {
        PrintToServer(
            "[SD-NNUE] no ranked candidate survived final validation: class=%d candidates=%d pathChecks=%d finalRejects=%d",
            zClass, count, pathChecks, finalRejects);
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
// 直接接收计算好的寻路极限距离 limitCost
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

    // 不再瞎算 limitCost，直接使用传进来的参数
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
stock void  PathCache_BuildKey(Address navGoal, Address navStart, float limitCost, char[] outKey, int maxlen)
{
    int idG = (navGoal != Address_Null) ? L4D_GetNavAreaID(navGoal) : -1;
    int idS = (navStart != Address_Null) ? L4D_GetNavAreaID(navStart) : -1;
    int q   = RoundToNearest(limitCost / fPathCacheQuantize);    // 量化，避免 key 激增
    Format(outKey, maxlen, "%d|%d|%d", idG, idS, q);
}
// 环境 & 限制

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
    // 读取当前的 sd_max_si 值
    // 无论是 CFG 加载的，还是你控制台手输入的，还是 API 改的，都以这个为准
    int limit = g_cvMaxSI.IntValue;

    // 基础安全范围 (防止设成 0 卡死或者设成 100 崩服)
    if (limit < 4) limit = 4;
    if (limit > 32) limit = 32;

    ConVar cvar;

    // 设置引擎总上限 (同步 sd_max_si 的值)
    if ((cvar = FindConVar("z_max_player_zombies")) != null)
    {
        cvar.SetBounds(ConVarBound_Upper, true, 32.0);
        cvar.SetInt(limit);
    }
    if ((cvar = FindConVar("z_minion_limit")) != null) cvar.SetInt(limit);
    if ((cvar = FindConVar("survival_max_specials")) != null) cvar.SetInt(limit);

    // 限制单类特感数量。
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

    // [修正] 距离参数 - 不再暴力覆盖！
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
    // 出门时记录当前距离，作为尸潮恢复的基准值
    g_fOriginalMinDist = g_cvSpawnDistMin.FloatValue;
    g_fOriginalMaxDist = g_cvSpawnDistMax.FloatValue;

    int   maxSI    = g_cvMaxSI.IntValue;
    float interval = g_cvHungerCooldown.FloatValue;
    float distMin  = g_cvSpawnDistMin.FloatValue;
    float distMax  = g_cvSpawnDistMax.FloatValue;

    PrintToChatAll("\x04[Sion]\x01 生还者离开安全区");
    PrintToChatAll("\x04[配置]\x01 特感上限: \x03%d \x01只 | 基准冷却: \x03%.1f \x01秒 \x05(动态)\x01", maxSI, interval);
    PrintToChatAll("\x04[参数]\x01 生成距离: \x03%.0f \x01- \x03%.0f", distMin, distMax);

    // 出门播报
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

    // 连续处理当前生成队列
    while (g_hSpawnQueue.Length > 0)
    {
        // 取出任务
        int class = g_hSpawnQueue.Get(0);
        g_hSpawnQueue.Erase(0);

        // --- 记账开始 ---
        // 生成请求发出前计入在途数量，避免主循环重复补充
        g_iTotalPending++;

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

// 事件 & 缓存
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bLeftSafeArea     = false;
    g_bTankSpawnedRound = false;
    g_fLastMobTime      = 0.0;
    // 每回合开始时，用当前 CVar 值初始化距离备份，防止还原为 0.0
    g_fOriginalMinDist  = g_cvSpawnDistMin.FloatValue;
    g_fOriginalMaxDist  = g_cvSpawnDistMax.FloatValue;
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
    // 终点拦截是否已触发
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

    // 回合结束时恢复原始生成距离，避免状态泄漏到下一回合
    g_cvSpawnDistMin.SetFloat(g_fOriginalMinDist);
    g_cvSpawnDistMax.SetFloat(g_fOriginalMaxDist);

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

    // 根据可行动生还者数量调整补充间隔
    float dynamicCD = SD_GetDynamicCooldown();
    if ((time - g_fLastSupplyTime) < dynamicCD) return Plugin_Continue;

    int currentTotal = SD_GetTotalSI_Strict();
    int maxSI        = g_cvMaxSI.IntValue;

    if (currentTotal >= maxSI || g_hSpawnQueue.Length > 0) return Plugin_Continue;

    SD_GenerateSquadWave();
    // 特殊尸潮机制
    int currentTier = g_cvDifficultyTier.IntValue;

    // 难度 5/6：Tank 存活期间每 15 秒触发一次尸潮
    if (currentTier >= 5 && SD_IsTankAlive())
    {
        if ((time - g_fLastTankMobTime) > 15.0)
        {
            g_fLastTankMobTime = time;
            SD_TriggerSurpriseMob();
            if (g_cvDebugMode.BoolValue) SD_Log("[第%d档] Tank存活，强制触发15s循环尸潮！", currentTier);
        }
    }
    // 接近终点时执行一次拦截逻辑
    int bestSurv = GetHighestFlowSurvivorSafe();
    int pct      = 0;
    if (IsValidSurvFast(bestSurv) && TryGetClientFlowPercentSafe(bestSurv, pct))
    {
        // 如果进度达到 96%，且这局还没触发过拦截
        if (pct >= 97 && !g_bTerminalIntercept)
        {
            g_bTerminalIntercept = true;    // 本回合只允许触发一次终点拦截
            int   culledCount    = 0;
            float leaderFlow     = g_fFlowCache[bestSurv];

            // 清理无法继续形成有效威胁的特感
            for (int i = 1; i <= MaxClients; i++)
            {
                if (g_iInfectedMask & (1 << i))
                {
                    int victim = SD_GetSIVictim(i);
                    if (victim > 0)
                    {
                        // 若控制目标已经倒地，则释放该特感槽位
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

            // 重建生成队列并填入控制类特感
            g_hSpawnQueue.Clear();
            for (int i = 0; i < maxSI; i++)
            {
                // 全部塞入硬控（牛/猴/舌/猎），不要胖子和口水了，终点前只要强控
                g_hSpawnQueue.Push(SD_PickRandomPinner());
            }
            SD_ShuffleQueue(g_hSpawnQueue);

            // 重置补充冷却
            // 将最后补充时间归零，使新队列立即进入处理流程
            g_fLastSupplyTime  = 0.0;
            g_fLastTankMobTime = time;    // 同时触发一波尸潮
            SD_TriggerSurpriseMob();

            // 输出终点拦截调试信息
            if (g_cvDebugMode.BoolValue)
            {
                SD_Log("[终局绝杀] 96%% 拌线触发！处死了 %d 只没用的特感，瞬间向前方空投全控阵容！", culledCount);
            }
        }
    }

    // 难度 6：接近终点后每 10 秒触发一次尸潮
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
public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{
    // 尸潮方向控制 (惊喜模式)
    if (g_bForceMobFront && StrEqual(key, "PreferredMobDirection", false))
    {
        retVal = 7;    // SPAWN_IN_FRONT_OF_SURVIVORS
        return Plugin_Handled;
    }

    // [原有] 配合你自定义的寻位逻辑
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

    // 禁用原生 Director 的普通特感补充，由插件统一控制
    // 只要原生导演（或地图机关）试图查询配额，永远返回 0
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
// 更新客户端状态缓存与位掩码
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

            // 使用 true 参数获取平方距离，比较 100*100 = 10000
            // 避免了 expensive 的 sqrt 运算
            if (GetVectorDistance(currentPos, g_vLastFlowPos[i], true) > 10000.0)
            {
                float safeFlow;
                // 只有获取到真实安全的进度，才覆盖缓存如果是断层，保留上一次的正确进度
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
void SD_CullLaggingSI_Fast()
{
    if (g_iInfectedMask == 0) return;

    // 清理距离不得小于最大生成距离，并额外保留缓冲区
    float cullDist    = g_cvCullDistance.FloatValue;
    float safeMinDist = g_cvSpawnDistMax.FloatValue + 300.0;    // 留出 300 码的缓冲区
    if (cullDist < safeMinDist) cullDist = safeMinDist;

    float cullDistSq        = cullDist * cullDist;
    // 前方特感使用更大的清理距离，避免误删仍可参与战斗的单位
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
            // 生成后 8 秒内不执行清理，预留落地与寻路时间
            if (time - g_fSpawnTime[i] < 8.0) continue;
            // 正在控人的特感绝对不杀
            if (SD_IsSIPinning(i)) continue;

            // 对长时间静止且落后于队伍的特感执行清理

            float vel[3];
            GetEntPropVector(i, Prop_Data, "m_vecVelocity", vel);
            float speedSq   = vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2];

            // 静止判定阈值与补充冷却联动，避免过早清理
            float idleLimit = g_cvHungerCooldown.FloatValue + 4;

            if (speedSq < 15.0 && (time - g_fSpawnTime[i] > idleLimit))
            {
                float siFlow = L4D2Direct_GetFlowDistance(i);

                // 使用 Flow 判断特感位于队伍前方还是后方
                // 若特感 Flow 落后于队伍领头进度，可判定其已失去有效威胁位置
                // 如果 siFlow >= leaderFlow，说明是在前方准备阴人（比如蹲角落），继续留着！
                if (siFlow != -9999.0 && siFlow < leaderFlow)
                {
                    ForcePlayerSuicide(i);
                    continue;    // 已经处死，直接跳过后续判断
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

            // 距离生还者足够近，说明已参战且正在移动（因为上面的罚站检测没杀它），不清理
            if (nearestActiveDistSq < cullDistSq) continue;

            float siFlow   = L4D2Direct_GetFlowDistance(i);
            bool  isBehind = (siFlow != -9999.0 && siFlow < leaderFlow);

            // [逻辑分流]
            if (isBehind)
            {
                // 落后处死：只要它被甩在队伍后面，且距离 > cullDist，立刻处死腾槽位
                ForcePlayerSuicide(i);
                continue;
            }
            else
            {
                // 视野检测保护：即使在前方，只要被玩家看到了就留着它
                if (GetEntProp(i, Prop_Send, "m_hasVisibleThreats") > 0) continue;

                // 前方过远处死：只有当它在正前方且离玩家极远 (3倍处死距离外)，才杀掉防止卡图
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

        // 第2档及以上，出克才附赠一波普通尸潮
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
// 引擎候选生成回退路径
// rangeOverride: 允许覆盖默认距离，传入 -1.0 则使用 g_cvSpawnDistMax
bool SD_AttemptEngineSpawn(int zClass, int target, float rangeOverride = -1.0)
{
        // 如果传入的目标无效，则自动回退到"路程最远"的生还者
    if (target <= 0 || !IsClientInGame(target) || !IsPlayerAlive(target) || GetClientTeam(target) != 2)
    {
        target = L4D_GetHighestFlowSurvivor();
        if (target <= 0) return false;    // 实在没人了
    }

    // 临时保存并调整引擎生成参数
    ConVar cvRange = FindConVar("z_spawn_range");
    ConVar cvSafe  = FindConVar("z_safe_spawn_range");

    if (cvRange == null || cvSafe == null) return false;    // 防御性编程

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

    // 兜底最小值，防止引擎无法计算
    if (searchRange < 250) searchRange = 250;

    // 临时调整引擎生成范围
    cvRange.SetInt(searchRange);
    cvSafe.SetInt(0);    // 引擎层放开安全距离限制，最终可见性由插件过滤

    // 开启 Hook 开关 (让插件接管 Spawn 位置判断)
    g_bIsPluginSpawning = true;

    float pos[3];
    bool  validSpotFound = false;

    // 最多请求引擎 10 次候选位置
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
            g_fSpawnTime[zombie] = GetEngineTime();    // 记录生成时间，供清理保护期使用
            if (g_iTotalPending > 0) g_iTotalPending--;    // 生成成功后立即结算在途数量

            // SetEntityFlags(zombie, GetEntityFlags(zombie) | FL_DUCKING);

            // 日志
            if (g_cvDebugMode.BoolValue)
            {
                SD_LogSpawnEvent(zClass, target, pos);
            }

                        g_iSpawnGhosts[zClass]++;
            CreateTimer(0.5, Timer_ClearGhost, zClass, TIMER_FLAG_NO_MAPCHANGE);
        }
    }

    // [重要] 还原现场，无论成功失败
    g_bIsPluginSpawning = false;
    cvRange.SetInt(oldRange);
    cvSafe.SetInt(oldSafe);

    return spawned;
}

bool SD_SpawnWithNavBucket(int class, int target)
{
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
        else if (g_hGriefTargets.FindString(auth) != -1)
        {
            distMin = 50.0;
            distMax = 350.0;
            reqVis  = false;
            isGrief = true;
        }
    }

    // 第5/6档：胖子极速贴脸 (无视视野，卡在 50~150 码内)
    if (g_cvDifficultyTier.IntValue >= 5 && class == ZC_BOOMER)
    {
        distMin = 50.0;
        distMax = 150.0;
        reqVis  = true;
        isGrief = false;
    }

    // 普通特感直接进入 NNUE 候选排序；NNUE 失败或后端未就绪时才使用引擎回退。
    if (SDNNUE_IsOperationalForClass(class)
        && SDNNUE_TrySpawnRanked(class, target, distMin, distMax, reqVis))
    {
        if (isGrief) PrintToChat(target, "\x04[Sion]\x01 \x03Surprise! \x01(无视视野贴脸)");
        return true;
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
        g_fSpawnTime[zombie] = GetEngineTime();    // 已经加了的精确时间

        // 瞬间销账，不再等待滞后的 Event
        if (g_iTotalPending > 0) g_iTotalPending--;

        g_iSpawnGhosts[class]++;
        CreateTimer(0.5, Timer_ClearGhost, class, TIMER_FLAG_NO_MAPCHANGE);
        if (g_cvDebugMode.BoolValue) SD_LogSpawnEvent(class, target, pos);
        return true;
    }
    return false;
}
public Action Timer_ClearGhost(Handle timer, int class)
{
    // 只有大于0才减，防止减成负数
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
        if (victim != attacker) return Plugin_Handled;    // 阻止特感互殴
        // 阻止胖子炸到队友
        if (GetEntProp(attacker, Prop_Send, "m_zombieClass") == ZC_BOOMER && (damagetype & DMG_BLAST)) return Plugin_Handled;
    }

    return Plugin_Continue;
}

bool SD_IsSurvivorTeamAlive() { return (g_iSurvivorMask != 0); }


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

/**
 * 按地图记录生成事件，包含目标、距离和坐标
 */
void SD_LogSpawnEvent(int zClass, int target, float spawnPos[3])
{
    float targetEye[3];
    GetClientEyePosition(target, targetEye);
    float dist = GetVectorDistance(targetEye, spawnPos);

    // 查表法
    char  sName[16];
    if (zClass >= 1 && zClass <= 8) strcopy(sName, sizeof(sName), g_sClassNames[zClass]);
    else strcopy(sName, sizeof(sName), "Unknown");

    SD_Log("----------------------------------------------------------------");
    SD_Log("[生成] %-8s -> 目标: %-8N (距离: %5.1f) | 坐标: %.0f, %.0f, %.0f", sName, target, dist, spawnPos[0], spawnPos[1], spawnPos[2]);
}

void SD_Log(const char[] format, any...)
{
    if (g_cvDebugMode.IntValue < 1) return;

    // 格式化原始消息
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);

    // 加上时间戳
    char timeStr[32];
    FormatTime(timeStr, sizeof(timeStr), "%H:%M:%S");

    char finalMsg[1024];
    Format(finalMsg, sizeof(finalMsg), "[%s] %s", timeStr, buffer);

    // 日志按当前地图分别写入文件
    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));

    char path[PLATFORM_MAX_PATH];
    // 路径格式: logs/smart_director_c5m2_park.log
    BuildPath(Path_SM, path, sizeof(path), "logs/smart_director_%s.log", mapName);

        LogToFileEx(path, "%s", finalMsg);
}

// 均衡选怪算法
int SD_PickBalancedPinner(bool useLimit, int limitCap)
{
    // 定义所有控制类特感
    int candidates[]   = { ZC_SMOKER, ZC_HUNTER, ZC_JOCKEY, ZC_CHARGER };
    int candidateCount = 4;

    // 如果不启用限制，直接随机返回
    if (!useLimit)
    {
        return candidates[GetRandomInt(0, candidateCount - 1)];
    }

    // 构建合格候选池 (Valid Pool)
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

    // 从候选池中随机抽取
    int result = ZC_HUNTER;    // 兜底默认值

    if (validPool.Length > 0)
    {
        result = validPool.Get(GetRandomInt(0, validPool.Length - 1));
    }
    else {
        // 若所有控制类均达到限制，则进入回退选择
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
void SD_GenerateSquadWave()
{
    int maxSI        = g_cvMaxSI.IntValue;
    int currentTotal = SD_GetTotalSI_Strict();
    int slotsNeeded  = maxSI - currentTotal;

    if (slotsNeeded <= 0) return;

    int  fcChance      = GetLogicChance_FullControl();
    bool isFullControl = (GetRandomInt(1, 100) <= fcChance);

    // 第5/6档：Tank 存活时强行剥夺吐痰和胖子，全是硬控
    if (g_cvDifficultyTier.IntValue >= 5 && SD_IsTankAlive())
    {
        isFullControl = true;
    }

    if (g_cvDebugMode.BoolValue && isFullControl)
    {
        SD_Log("[导演] 全控阵容启动");
    }

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
            // 模拟一整波从四面八方刷出——对每个站立的生还者都触发幻听
            // 效果：全队同时听到不同方向的进攻声，以为被全方位包围
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
        // 极速判断是否为特感
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
// 惊喜模式逻辑

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
        // 开启强制前方开关
        g_bForceMobFront = true;

        // 定时关闭前方强制生成状态，避免影响后续普通尸潮
        CreateTimer(6.0, Timer_ResetMobForce, _, TIMER_FLAG_NO_MAPCHANGE);

        // 执行尸潮命令
        int flags = GetCommandFlags("z_spawn_old");
        SetCommandFlags("z_spawn_old", flags & ~FCVAR_CHEAT);
        FakeClientCommand(target, "z_spawn_old mob");
        SetCommandFlags("z_spawn_old", flags);

    }
}

// 重置尸潮方向开关
public Action Timer_ResetMobForce(Handle timer)
{
    g_bForceMobFront = false;
    return Plugin_Stop;
}

stock float Clamp01(float v)
{
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}
// [调试] Nav & Bucket 详细信息查看器
public Action Cmd_NavDebug(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    // 获取玩家位置
    float pos[3];
    GetClientAbsOrigin(client, pos);

    // 获取最近的 Nav Area
    // 使用 120.0 范围，模拟特感生成的判定宽松度
    Address nav = L4D_GetNearestNavArea(pos, 120.0, false, false, false, TEAM_INFECTED);

    if (nav == Address_Null)
    {
        PrintToChat(client, "\x04[Debug]\x01 当前位置 \x03无法找到 NavArea\x01 (悬空或地图外?)");
        return Plugin_Handled;
    }

    // 获取原生 Nav 数据
    int   id    = L4D_GetNavAreaID(nav);
    int   flags = L4D_GetNavArea_SpawnAttributes(nav);
    float flow  = L4D2Direct_GetTerrorNavAreaFlow(nav);
    float center[3];
    L4D_GetNavAreaCenter(nav, center);

    // 获取插件构建的缓存数据 (分桶信息)
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

    // 视觉反馈 (画线：脚底 -> Nav中心)
    float visualPos[3];
    visualPos = pos;
    visualPos[2] += 10.0;
    TE_SetupBeamPoints(visualPos, center, PrecacheModel("sprites/laserbeam.vmt"), 0, 0, 0, 5.0, 2.0, 2.0, 10, 0.0, { 255, 0, 0, 255 }, 0);
    TE_SendToAll();

    // 控制台详细输出
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
                PrintToConsole(client, ">> 警告: 玩家当前高度超出了该桶的缓存范围！可能导致跳过生成");
        }
    }
    else
    {
        PrintToConsole(client, ">> 错误: 此 NavArea 未在缓存中找到！(索引 -1)");
        PrintToConsole(client, ">> 可能原因: 1. 地图没完全加载 2. Flow断层 3. 内存构建失败");
    }
    PrintToConsole(client, "=============================================");

    // 聊天框简略输出
    PrintToChat(client, "\x04[Debug]\x01 Nav: \x03%d \x01| Flow: \x04%.0f", id, flow);
    if (isCached)
        PrintToChat(client, "\x04[Bucket]\x01 Pct: \x05%d%% \x01| Z-Delta: %.1f", bucket, pos[2] - zCore);
    else
        PrintToChat(client, "\x04[Bucket]\x01 \x02未缓存/无效区域");

    return Plugin_Handled;
}

// 辅助：解析 Nav 标志位并打印
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
// [调试] Flow Stream Visualizer (流向可视化)
// Flow 路径可视化调试
// [调试] Flow Stream Visualizer (动态实时版)
public Action Cmd_NavDebugFlow(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    // 切换开关状态
    g_bFlowDebug[client] = !g_bFlowDebug[client];

    if (g_bFlowDebug[client])
    {
        PrintToChat(client, "\x04[Flow]\x01 动态导航已 \x03开启\x01跟随你的步伐显示前方路径...");

        // 如果计时器没启动，启动它
        if (g_hFlowDebugTimer == null)
        {
            // 以固定间隔刷新可视化结果
            g_hFlowDebugTimer = CreateTimer(0.2, Timer_FlowDebugThink, _, TIMER_REPEAT);
        }
    }
    else
    {
        PrintToChat(client, "\x04[Flow]\x01 动态导航已 \x04关闭\x01");

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

// 绘制当前 Flow 路径
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

            // Beam 生命周期略长于刷新间隔，保持视觉连续
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
// 在 OnMapStart 或 BuildNavBuckets 之后调用
void BuildLogicCache()
{
    g_bLogicReady = false;

    // 尝试从文件读取 (如果有缓存，直接读，省去计算)
    if (TryLoadLogicFromCache())
    {
        g_bLogicReady = true;
        return;
    }

    // 缓存不存在，开始计算数学曲线

    for (int i = 0; i <= 100; i++)
    {
        float progress = float(i) / 100.0;    // 0 -> 1.0

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
        kv.SetNum("mf", g_ProbMobFront[i]);    // Mob Front Chance
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
// 获取当前的特感总数（现状 + 预期）
int SD_GetTotalSI_Strict()
{
    int count = 0;

    // 第一部分：询问引擎“现状”（已经存在的）
    for (int i = 1; i <= MaxClients; i++)
    {
        // 必须在游戏中
        if (!IsClientInGame(i)) continue;

        // 必须是感染者阵营
        if (GetClientTeam(i) != 3) continue;

        // 排除死人 (防止死体占位导致的误判)
        // 仅统计仍然存活的普通特感
        if (!IsPlayerAlive(i)) continue;

        // (可选) 排除幽灵状态
        if (IsFakeClient(i) && GetEntProp(i, Prop_Send, "m_isGhost") == 1) continue;

        count++;
    }

    // 第二部分：加上你自己的“预期”（在途的 + 队列里的）

    // 计入等待处理的生成队列
    count += g_hSpawnQueue.Length;

    // 计入已经发出但尚未完成的生成请求
    // 这个变量是你为了弥补"引擎真空期"而必须手动维护的
    count += g_iTotalPending;

    // 加上已经成型但还没脱离幽灵状态的
    for (int i = 1; i <= 6; i++)
    {
        count += g_iSpawnGhosts[i];
    }

    return count;
}
int GetLogicChance_FullControl()
{
    if (!g_bLogicReady) BuildLogicCache();    // 懒加载：如果还没准备好，现在立刻构建

    // 找到跑得最远的生还者
    int bestSurv = GetHighestFlowSurvivorSafe();
    int pct      = 0;

    // 算他的百分比
    if (IsValidSurvFast(bestSurv))
    {
        TryGetClientFlowPercentSafe(bestSurv, pct);
    }

    // 查表返回概率
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
    // 安全检查
    if (client == 0)
    {
        ReplyToCommand(client, "[Sion] 控制台无法使用此命令");
        return Plugin_Handled;
    }

    // [权限检查] 只有最高管理员 或 ROOT 权限可以使用
    // CheckCommandAccess 这里用于判断是否有 root 权限 override
    bool isSuper = IsSuperAdmin(client);
    bool isRoot  = CheckCommandAccess(client, "sm_sd_grief_override", ADMFLAG_ROOT, true);

    if (!isSuper && !isRoot)
    {
        ReplyToCommand(client, "\x04[Sion]\x01 权限不足：只有 \x03最高管理员 \x01可以操作恶搞名单");
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
        ReplyToCommand(client, "\x04[Sion]\x01 错误：无法获取该玩家 SteamID (可能是机器人或未完全连接)");
        return Plugin_Handled;
    }

    // [反噬保护] 防止把最高管理员自己加进去
    if (StrEqual(auth, SUPER_ADMIN_STEAMID))
    {
        ReplyToCommand(client, "\x04[Sion]\x01 \x02错误：\x01你不能把 \x03最高管理员 (你自己) \x01加入恶搞名单！");
        return Plugin_Handled;
    }

    // 读写逻辑 (写入到内存数组)
    int index = g_hGriefTargets.FindString(auth);

    if (index != -1)
    {
        // --- [移除逻辑] ---
        // 如果已经在名单里，则执行删除
        g_hGriefTargets.Erase(index);

        ReplyToCommand(client, "\x04[Sion]\x01 \x03%N \x01已从名单移除，停止恶搞", target);
        if (isSuper) PrintToChat(client, "\x04[Sion]\x01 您的宽恕已生效，配置已保存");
    }
    else
    {
        // --- [添加逻辑] ---
        // 如果不在名单里，则执行添加
        g_hGriefTargets.PushString(auth);

        ReplyToCommand(client, "\x04[Sion]\x01 \x03%N \x01已加入豪华午餐！(贴脸模式开启)", target);
        if (isSuper) PrintToChat(client, "\x04[Sion]\x01 您的意志已执行，目标已写入黑名单文件");
    }

    // 变更后立即持久化
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
    // 使用 "w" 模式
    // 这会清空文件并重写当前内存里的所有名单
    // 这完美解决了"只能加不能删"的 Bug
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
// 应用当前难度档位配置
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

    // 状态机重置：清理高档位的残留配置
    if (cvCommonLimit != null) cvCommonLimit.SetInt(30);
    if (cvMegaMobSize != null) cvMegaMobSize.SetInt(50);
    if (cvMobSpawnMax != null) cvMobSpawnMax.SetInt(30);

    // 尊重用户覆盖：只有用户没手动改过的参数，才由难度系统管理
    if (!g_bUserOverride_MobCD)
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
        if (!g_bUserOverride_MobCD)
            g_cvmobcooldown.SetFloat(30.0);
    }

    // 重新应用用户覆盖的设定，确保跨关保持
    if (g_bUserOverride_TankControl)
        g_cvEnableTankControl.SetInt(g_iUserVal_TankControl);
    if (g_bUserOverride_MobCD)
        g_cvmobcooldown.SetFloat(g_fUserVal_MobCD);
}
// [第6档专属] 无声特感：全局屏蔽特感发声逻辑
public Action Hook_NormalSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
    // 解耦判断：独立开关开启，或者处于第 6 档时，才进行拦截
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

        // 在刚才计算出的坐标引爆这颗“声音炸弹”
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

    // 随机选择一个有效生还者作为声音目标
    int victim      = SD_GetBestStrategicTarget();
    if (victim <= 0) victim = SD_GetRandomSurvivor();    // 如果没有最佳目标，就随便抽一个存活的

    // 如果有人活着，就播放幻听
    if (victim > 0)
    {
        SD_PlayPhantomSound(victim);    // 调用我们上一回合写好的发声函数
    }

    // 按随机间隔重新调度下一次幻听
    float minTime   = g_cvPhantomIntervalMin.FloatValue;
    float maxTime   = g_cvPhantomIntervalMax.FloatValue;
    float nextDelay = GetRandomFloat(minTime, maxTime);

    g_hPhantomTimer = CreateTimer(nextDelay, Timer_PhantomLoop);

    return Plugin_Stop;
}
// 获取特感当前正在控制的生还者实体索引
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

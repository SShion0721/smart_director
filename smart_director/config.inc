
#define SUPER_ADMIN_STEAMID "STEAM_0:0:814326156"
#define PERMANENT_VICTIM    "STEAM_1:0:560277037"

// 基础配置与运行状态
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

// 指定目标名单
ArrayList g_hGriefTargets;
char      g_sGriefFilePath[PLATFORM_MAX_PATH];

int       g_iTotalPending = 0;    // 已下发生成请求、但实体还未创建的数量

#define IsValidClient(%1)   (%1 > 0 && %1 <= MaxClients && IsClientInGame(%1))
#define IsAlive(%1)         (IsPlayerAlive(%1))

// 位掩码是只读缓存。
// 事件回调后必须刷新 UpdateClientCache。
#define IsValidSurvFast(%1) (g_iSurvivorMask & (1 << %1))
#define IsValidInfFast(%1)  (g_iInfectedMask & (1 << %1))

static int  g_ProbFullControl[101];    // 全控概率表 (0-100%)
static int  g_ProbMobFront[101];    // 前方尸潮概率表 (0-100%)
static char g_sLogicCachePath[PLATFORM_MAX_PATH] = "";
static bool g_bLogicReady                        = false;

// 路程概率曲线；指数决定压力向后半程集中的程度。
#define LOGIC_CURVE_EXP   2.5    // 越大，压力越集中在后半程
#define LOGIC_BASE_CHANCE 5.0    // 起点概率
#define LOGIC_MAX_CHANCE  90.0    // 终点概率

// 特感名称只用于日志。
char      g_sClassNames[][] = { "Unknown", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger", "Witch", "Tank" };

int       g_iSurvivorMask   = 0;
int       g_iInfectedMask   = 0;    // 存活普通特感掩码，不含 Tank
int       g_iSpawnGhosts[10];

// 每回合只允许触发一次终点拦截。
bool      g_bTerminalIntercept = false;
// 尸潮冷却基准。
float     g_fLastMobTime       = 0.0;

// 生成期间屏蔽插件自身 Hook 的干扰。
bool      g_bIsPluginSpawning  = false;

ConVar    g_cvPhantomMaxSounds;    // 单次最多播放的声音数

ConVar    g_cvMaxSI;
ConVar    g_cvSpawnDistMin;
ConVar    g_cvSpawnDistMax;
ConVar    g_cvEnableTankControl;
ConVar    g_cvCullDistance;
ConVar    g_cvDebugMode;
ConVar    g_cvHungerCooldown;    // 补充特感的冷却
ConVar    g_cvLimitBatchHalf;    // 单批同类数量不超过队列一半
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
bool      g_bSuperMode        = false;
bool      g_bPanicMode        = false;    // 尸潮或守点阶段
float     g_fOriginalMinDist;    // 退出尸潮状态时恢复
float     g_fOriginalMaxDist;    // 退出尸潮状态时恢复
Handle    g_hPanicEndTimer  = null;    // 超时后自动退出尸潮状态

float     g_fNextTankTime   = 0.0;
float     g_fLastSupplyTime = 0.0;
bool      g_bLateLoad       = false;
bool      g_bLeftSafeArea   = false;

float     g_fFlowCache[MAXPLAYERS + 1];
float     g_vLastFlowPos[MAXPLAYERS + 1][3];
bool      g_bIsPinned[MAXPLAYERS + 1];
bool      g_bIsIncap[MAXPLAYERS + 1];
bool      g_bIsBiled[MAXPLAYERS + 1];
float     g_fSpawnTime[MAXPLAYERS + 1];

bool      g_bForceMobFront = false;    // 强制尸潮在队伍前方生成

bool      g_bUserOverride_TankControl = false;    // 用户是否手动改过 Tank 控制
bool      g_bUserOverride_MobCD       = false;    // 用户是否手动改过尸潮冷却
int       g_iUserVal_TankControl      = 1;    // 用户设定的 Tank 控制值
float     g_fUserVal_MobCD            = 60.0;    // 用户设定的 Mob 冷却值

int       g_iCachedTeam[MAXPLAYERS + 1];
bool      g_bCachedAlive[MAXPLAYERS + 1];
bool      g_bCachedInGame[MAXPLAYERS + 1];

// 幻听定时器
ConVar    g_cvPhantomIntervalMin;
ConVar    g_cvPhantomIntervalMax;
Handle    g_hPhantomTimer = null;

enum struct SurPosData
{
    float fFlow;
    float fPos[3];
}

// 最终刷点的评分明细，只在调试日志中输出。
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

// Nav 缓存与刷点评分

// Nav Flow 分桶
#define FLOW_BUCKETS     101    // 100
#define BUCKET_CACHE_VER "2026.2.10"    // 缓存格式版本

// 全地图 NavArea 缓存。
static ArrayList g_AllNavAreasCache   = null;
static int       g_NavAreasCacheCount = 0;
// 每个区域的代表高度，以及每个 Flow 桶的高度范围。
static ArrayList g_AreaZCore          = null;
static ArrayList g_AreaZMin           = null;
static ArrayList g_AreaZMax           = null;
static float     g_BucketMinZ[FLOW_BUCKETS];
static float     g_BucketMaxZ[FLOW_BUCKETS];

static StringMap g_NavIdToIndex                        = null;    // NavArea ID -> 缓存下标
static char      g_sBucketCachePath[PLATFORM_MAX_PATH] = "";

// Nav Flow 分桶
static ArrayList g_FlowBuckets[FLOW_BUCKETS];    // 每桶存 NavArea 索引 i
static bool      g_BucketsReady = false;

// 区域中心点与预计算 Flow 百分比。
static ArrayList g_AreaCX       = null;
static ArrayList g_AreaCY       = null;
static ArrayList g_AreaPct      = null;

float            fNavBucketAssignRadius;    // 就近归桶半径；0 表示不限制
bool             bNavCacheEnable;
ConVar           VsBossFlowBuffer;
bool             bNavBucketMapInvalid;
// 同批次刷点的空间分离参数。
#define SEP_TTL            3.0    // 最近刷点保留秒数
#define SEP_RADIUS         80.0

ArrayList lastSpawns = null;    // 每条记录为 [x, y, z, time]

// Nav 分桶

float     g_fMapMaxFlow = 0.0;    // 地图最大 Flow 距离（用于归一化百分比）

methodmap NavArea
{

    // 统一通过 Left4DHooks 访问 NavArea。
public     void GetRandomPoint(float outPos[3])
    {
        L4D_FindRandomSpot(view_as<int>(this), outPos);
    }

public     float GetFlow()
    {
        return L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(this));
    }
}

// 调试输出使用的 Nav 标志位。
enum
{
    TERROR_NAV_EMPTY             = 1 << 1,
    TERROR_NAV_STOP_SCAN         = 1 << 2,
    TERROR_NAV_CHECKPOINT        = 1 << 11,
    TERROR_NAV_OBSCURED          = 1 << 12,
    TERROR_NAV_NO_MOBS           = 1 << 13,
    TERROR_NAV_THREAT            = 1 << 14,
    TERROR_NAV_RESCUE_VEHICLE    = 1 << 15,
    TERROR_NAV_RESCUE_CLOSET     = 1 << 16,
    TERROR_NAV_ESCAPE_ROUTE      = 1 << 17,
    TERROR_NAV_NOTHREAT          = 1 << 19
}

public Plugin myinfo =
{
    name        = "Smart Director",
    author      = "Sion Gemini",
    description = "Progress-aware special infected director",
    version     = "22.0",
    url         = "https://steamcommunity.com/profiles/76561199209427576"
};

// 对外 API

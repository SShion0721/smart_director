static bool IsFlowAbnormal(float flowDist, float maxFlow)
{
    if (maxFlow <= 0.0) return true;
    return (flowDist < 0.0 || flowDist > maxFlow);
}

// Flow 读取失败时依次尝试 LastKnownArea 和最近 NavArea。
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

// 动态补货冷却：根据"战斗力"自动调整
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
    return result;
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

stock int GetNavIDByIndex(int idx)
{
    EnsureNavAreasCache();    // 确保缓存存在

    if (idx < 0 || idx >= g_NavAreasCacheCount)
        return -1;

    Address area = g_AllNavAreasCache.Get(idx);
    return L4D_GetNavAreaID(area);
}

stock bool PassMinSeparation(const float pos[3])
{
    if (lastSpawns == null || lastSpawns.Length == 0) return true;

    float now            = GetGameTime();
    float sep2 = SEP_RADIUS * SEP_RADIUS;

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

// 取得“当前有效的回退进度”（满足开启且未过期）

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
    if (entity <= MaxClients) return false;    // 忽略玩家
    if (!IsValidEntity(entity)) return false;

    // [极致优化] 避免字符串操作
    // 普通丧尸(Infected) 和 Witch 都有特定的 Classname 字符串
    // 这里只需要区分会阻挡 Hull 的实体，不做完整类别判断。

    // 方法 A: 检查 collision group (如果已知)
    // 方法 B: 检查 m_iTeamNum (丧尸通常是 Team 3)
    // NPC 类实体不参与卡位判断。

    // 先按首字符过滤，避免每次 Trace 都做完整字符串比较。
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


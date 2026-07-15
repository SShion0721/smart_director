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

// 波次编排
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
    // 在可用控制特感之间尽量均摊。
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
        // 只统计普通特感。
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

        // 设置一个计时器，5秒后自动关闭开关 (防止影响后续的普通尸潮)
        CreateTimer(6.0, Timer_ResetMobForce, _, TIMER_FLAG_NO_MAPCHANGE);

        // 执行尸潮命令
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

// Nav & Bucket 详细信息查看器

// 调试命令
public Action Cmd_NavDebug(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    float pos[3];
    GetClientAbsOrigin(client, pos);

    // 使用 120.0 范围，模拟特感生成的判定宽松度
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

    // 获取插件构建的缓存数据 (分桶信息)
    int   idx    = GetAreaIndexByNavID_Int(id);    // ArrayList 中的缓存下标
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

    // 视觉反馈 (画线：脚底 -> Nav中心)
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

    // 聊天框简略输出
    PrintToChat(client, "\x04[Debug]\x01 Nav: \x03%d \x01| Flow: \x04%.0f", id, flow);
    if (isCached)
        PrintToChat(client, "\x04[Bucket]\x01 Pct: \x05%d%% \x01| Z-Delta: %.1f", bucket, pos[2] - zCore);
    else
        PrintToChat(client, "\x04[Bucket]\x01 \x02未缓存/无效区域");

    return Plugin_Handled;
}

// 把 Nav 标志位转成可读文本。
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
// Flow 动态显示开关
bool   g_bFlowDebug[MAXPLAYERS + 1];
Handle g_hFlowDebugTimer = null;

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
            // 2秒刷新一次，保证流畅且不卡服
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

// 按 Flow 顺序绘制当前玩家前方路径。
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

            // 生命周期略长于刷新间隔，避免线段闪烁。
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

// 路程概率表

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
    g_fOriginalMinDist = g_cvSpawnDistMin.FloatValue;
    g_fOriginalMaxDist = g_cvSpawnDistMax.FloatValue;

    int   maxSI    = g_cvMaxSI.IntValue;
    float interval = g_cvHungerCooldown.FloatValue;
    float distMin  = g_cvSpawnDistMin.FloatValue;
    float distMax  = g_cvSpawnDistMax.FloatValue;

    PrintToChatAll("\x04[Sion]\x01 生还者离开安全区。");
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

    // 爆发循环：只要队列有货，就一直刷
    while (g_hSpawnQueue.Length > 0)
    {
        // 取出任务
        int class = g_hSpawnQueue.Get(0);
        g_hSpawnQueue.Erase(0);

        // 告诉导演：这只怪已经下单了，虽然还没生出来，但别再补货了！
        g_iTotalPending++;

        // 尝试寻找位置
        int target = SD_GetBestStrategicTarget();
        if (target <= 0) target = SD_GetRandomSurvivor();

        bool spawned = false;
        if (target > 0)
        {
            // 下发生成请求。
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
    // 每回合只允许触发一次终点拦截。
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

// 导演主循环
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
    // 特殊尸潮机制
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

            // 终极无情大清洗
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

            // 瞬间爆兵：清空烂账，强制生成全控特感
            g_hSpawnQueue.Clear();
            for (int i = 0; i < maxSI; i++)
            {
                // 全部塞入硬控（牛/猴/舌/猎），不要胖子和口水了，终点前只要强控
                g_hSpawnQueue.Push(SD_PickRandomPinner());
            }
            SD_ShuffleQueue(g_hSpawnQueue);

            // 清掉幽灵冷却，避免生成成功后继续占用在途槽位。
            // 把最后供货时间重置为 0，这会导致 Timer_ProcessQueue 瞬间像疯狗一样开始派单
            g_fLastSupplyTime  = 0.0;
            g_fLastTankMobTime = time;    // 顺手召唤一波尸潮
            SD_TriggerSurpriseMob();

            // 气势拉满的提示
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

    // 继续使用插件自己的刷点与视线约束。
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
// 缓存更新函数 (必须替换原版)

// 玩家状态缓存

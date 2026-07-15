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

        // Tank 不计入普通特感位掩码。
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
    if (activeSurvivors == 0) leaderFlow = 0.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_iInfectedMask & (1 << i))
        {
            // 刚刷出来 8 秒内绝对不清理 (给足落地和寻路时间)
            if (time - g_fSpawnTime[i] < 8.0) continue;
            // 正在控人的特感绝对不杀
            if (SD_IsSIPinning(i)) continue;

            float vel[3];
            GetEntPropVector(i, Prop_Data, "m_vecVelocity", vel);
            float speedSq   = vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2];

            // 发呆容忍时间 = 补货冷却时间 + 8秒的跑图容忍度 (保证处死后秒补怪)
            float idleLimit = g_cvHungerCooldown.FloatValue + 4;

            if (speedSq < 15.0 && (time - g_fSpawnTime[i] > idleLimit))
            {
                float siFlow = L4D2Direct_GetFlowDistance(i);

                // 用 Flow 差判断特感位于队伍前方还是后方。
                // 如果 siFlow < leaderFlow，说明在后方挂机/卡墙/被垫底生还者溜。该杀！
                if (siFlow != -9999.0 && siFlow < leaderFlow)
                {
                    ForcePlayerSuicide(i);
                    continue;    // 已经处死，直接跳过后续判断
                }
            }

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
// 尝试生成 (引擎内核 + 视线过滤 + API控制)
// rangeOverride: 允许覆盖默认距离，传入 -1.0 则使用 g_cvSpawnDistMax
bool SD_AttemptEngineSpawn(int zClass, int target, float rangeOverride = -1.0)
{
    // 目标校验
    // 如果传入的目标无效，则自动回退到"路程最远"的生还者
    if (target <= 0 || !IsClientInGame(target) || !IsPlayerAlive(target) || GetClientTeam(target) != 2)
    {
        target = L4D_GetHighestFlowSurvivor();
        if (target <= 0) return false;    // 实在没人了
    }

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

    cvRange.SetInt(searchRange);
    cvSafe.SetInt(0);    // 引擎层放开距离限制，最终可见性由插件过滤。

    // 开启 Hook 开关 (让插件接管 Spawn 位置判断)
    g_bIsPluginSpawning = true;

    float pos[3];
    bool  validSpotFound = false;

    // [抽卡机制] 给引擎 10 次机会
    // safe_range 为 0 时必须再次做视线过滤。
    for (int i = 0; i < 10; i++)
    {
        // 外层已经重试，这里减少单次引擎尝试数。
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
            g_fSpawnTime[zombie] = GetEngineTime();    // 补发8秒免死保护
            if (g_iTotalPending > 0) g_iTotalPending--;    // 顺手解决我上次提到的烂账卡单问题

            if (g_cvDebugMode.BoolValue)
            {
                SD_LogSpawnEvent(zClass, target, pos);
            }

            // 幽灵计数管理
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

// 特感生成
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

    // 难度 5/6 允许 Boomer 在 50..150 范围内贴近生成。
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

// 辅助函数
public bool TraceFilter_WorldOnly(int entity, int contentsMask) { return entity == 0; }

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    // 使用宏判定
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
// 智能过滤器：忽略生物，但检测物理物件

/**
 * [日志系统] 升级版
 * 日志按地图分文件，并记录每次生成的目标、距离和坐标。
 */
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
    // 路径格式: logs/smart_director_c5m2_park.log
    BuildPath(Path_SM, path, sizeof(path), "logs/smart_director_%s.log", mapName);

    LogToFileEx(path, "%s", finalMsg);
}

// 均衡选怪算法

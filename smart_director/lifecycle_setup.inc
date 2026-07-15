public Action Event_PlayerDeath_Kick(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    // 如果是特感 bot
    if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == 3 && IsFakeClient(client))
    {
        // 标记为即将踢出，防止被 GetTotalSI_Strict 误判（虽然 IsPlayerAlive 已经防住了）
        // 1秒后踢出，给死亡动画一点面子，如果追求极致可以设为 0.0
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

// 插件主逻辑

// 插件生命周期
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
    // 注册常驻倒霉蛋开关 (默认为 1: 开启)
    g_cvGriefPermanentEnv  = CreateConVar("sd_grief_permanent", "0", "是否启用代码中写死的常驻倒霉蛋功能 (1=开启, 0=关闭)");
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
    // 初始化恶搞名单
    g_hGriefTargets = new ArrayList(ByteCountToCells(64));    // 存字符串需要转换大小
    BuildPath(Path_SM, g_sGriefFilePath, sizeof(g_sGriefFilePath), "data/sd_grief_targets.txt");
    LoadGriefTargets();    // 开局读取

    // 注册命令 (只有 ROOT 权限可用)
    RegAdminCmd("sm_sd_grief", Cmd_ToggleGrief, ADMFLAG_ROOT, "开关指定玩家的贴脸刷怪模式");
    // [Nav管理] 3. 注册命令 (用于调试)
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
    HookEvent("player_death", Event_PlayerDeath_Kick, EventHookMode_Pre);    // 用 Pre 更快地检测到死亡，及时销账

    HookEvent("player_team", Event_CacheUpdate);
    HookEvent("player_spawn", Event_CacheUpdate_Spawn);
    HookEvent("player_death", Event_CacheUpdate);
    HookEvent("player_disconnect", Event_CacheUpdate_Disconnect);

    RegAdminCmd("sm_sd_force_spawn", Cmd_ForceSpawn, ADMFLAG_ROOT, "强制生成");
    RegAdminCmd("sm_sd_force_tank", Cmd_ForceTank, ADMFLAG_ROOT, "强制Tank封路测试");

    PrecacheSound("player/hunter/voice/attack/hunter_shriek_1.wav");    // Hunter 飞扑尖叫
    PrecacheSound("player/boomer/voice/attack/boomer_attack_01.wav");    // Boomer 吐胆汁的瞬间
    PrecacheSound("player/smoker/voice/attack/smoker_attack_01.wav");    // Smoker 吐舌头
    PrecacheSound("player/jockey/voice/attack/jockey_attack_01.wav");    // Jockey 起跳怪叫
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
    // 这样能模拟“四面楚歌”的感觉，因为守点时玩家通常不动，远处的怪没有威胁
    g_cvSpawnDistMin.SetFloat(100.0);
    g_cvSpawnDistMax.SetFloat(600.0);
    UnlockLimits();    // 应用到引擎

    PrintToChatAll("\x04[Sion]\x01 : \x03尸潮爆发！\x01特感距离已压缩，AOE配额提升！");

    // 设置复位定时器
    // 没有可靠的尸潮结束事件，使用保守超时退出。
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

    // 模式 1: 仅检查特定目标
    if (mode == 1 && IsValidClient(target))
    {
        if (L4D2_IsVisibleToPlayer(target, TEAM_SURVIVOR, TEAM_INFECTED, 0, checkPos)) return true;
        return false;
    }

    // 模式 2：检查全队。
    for (int i = 1; i <= MaxClients; i++)
    {
        // 使用事件维护的位掩码，避免重复查询队伍状态。
        if (IsValidSurvFast(i))
        {
            if (L4D2_IsVisibleToPlayer(i, TEAM_SURVIVOR, TEAM_INFECTED, 0, checkPos)) return true;
        }
    }
    return false;
}

// 刷点搜索
bool SD_FindNavSpawnPos_Advanced(int targetClient, float minRange, float maxRange, bool reqVis, float outPos[3])
{
    if (!g_BucketsReady) return false;
    float targetPos[3];
    GetClientAbsOrigin(targetClient, targetPos);

    int targetPercent = 0;
    TryGetClientFlowPercentSafe(targetClient, targetPercent);

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
    bool ok = L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false);
    return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
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
    // 所有入口最终都以 sd_max_si 的当前值为准。
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

    // 超级模式放开单类上限；普通模式保留原版分布。
    // 逻辑：如果是超级模式，所有单类上限直接解锁到总上限 (limit)，由代码比例控制。

    int typeLimit   = g_bSuperMode ? limit : 4;
    int boomerLimit = g_bSuperMode ? limit : 2;

    if ((cvar = FindConVar("z_smoker_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_boomer_limit")) != null) cvar.SetInt(boomerLimit);
    if ((cvar = FindConVar("z_hunter_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_spitter_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_jockey_limit")) != null) cvar.SetInt(typeLimit);
    if ((cvar = FindConVar("z_charger_limit")) != null) cvar.SetInt(typeLimit);

    // [修正] 距离参数 - 不再暴力覆盖！
    // 引擎生成范围至少覆盖插件允许的最远刷点。

    float myMaxDist   = g_cvSpawnDistMax.FloatValue;
    // 引擎的 z_spawn_range 必须大于插件的 max，否则引擎会强行杀掉刷出来的怪
    int   engineRange = RoundToCeil(myMaxDist + 500.0);
    if (engineRange < 2000) engineRange = 2000;    // 兜底

    if ((cvar = FindConVar("z_spawn_range")) != null) cvar.SetInt(engineRange);

    // 自动清理距离：设得比生成距离远 1000 码，防止刚刷出来就被清理
    if ((cvar = FindConVar("z_discard_range")) != null) cvar.SetInt(engineRange + 1000);

    // 允许贴脸生成 (由插件代码控制可见性，引擎层放开)
    if ((cvar = FindConVar("z_safe_spawn_range")) != null) cvar.SetInt(0);

    // 更新内部配额
}


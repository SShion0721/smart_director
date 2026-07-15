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

        // 公式: Base + (Max - Base) * (x ^ Exp)
        // 例如 Exp=2.5 时，50%路程时概率依然很低，但80%后会飙升
        float chanceFC = LOGIC_BASE_CHANCE + (LOGIC_MAX_CHANCE - LOGIC_BASE_CHANCE) * Pow(progress, LOGIC_CURVE_EXP);

        // 特殊处理：救援关 (Finale) 的最后阶段 (90%+) 压力拉满
        if (L4D_IsMissionFinalMap() && i > 90) chanceFC = 100.0;

        g_ProbFullControl[i] = RoundToNearest(chanceFC);
        if (g_ProbFullControl[i] > 100) g_ProbFullControl[i] = 100;

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

    // 询问引擎“现状”（已经存在的）
    for (int i = 1; i <= MaxClients; i++)
    {
        // 必须在游戏中
        if (!IsClientInGame(i)) continue;

        // 必须是感染者阵营
        if (GetClientTeam(i) != 3) continue;

        // 排除死人 (防止死体占位导致的误判)
        // 死亡实体和幽灵实体都不占有效槽位。
        if (!IsPlayerAlive(i)) continue;

        // (可选) 排除幽灵状态
        if (IsFakeClient(i) && GetEntProp(i, Prop_Send, "m_isGhost") == 1) continue;

        count++;
    }

    count += g_hSpawnQueue.Length;

    // 在途请求同样占槽，避免引擎创建前的计数真空。
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

// 指定目标名单
public Action Cmd_ToggleGrief(int client, int args)
{
    // 安全检查
    if (client == 0)
    {
        ReplyToCommand(client, "[Sion] 控制台无法使用此命令。");
        return Plugin_Handled;
    }

    // [权限检查] 只有最高管理员 或 ROOT 权限可以使用
    // 权限使用 SourceMod override，便于服务器配置覆盖。
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
        // 如果已经在名单里，则执行删除
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

    // 修改后立即落盘。
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
// 难度档位直接映射到运行参数，不经过投票。
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

    if (g_bUserOverride_TankControl)
        g_cvEnableTankControl.SetInt(g_iUserVal_TankControl);
    if (g_bUserOverride_MobCD)
        g_cvmobcooldown.SetFloat(g_fUserVal_MobCD);
}
// [第6档专属] 忍者特感：全局屏蔽特感发声逻辑

// 幻听系统

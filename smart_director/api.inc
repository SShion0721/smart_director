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
    // 第一个参数决定是否启用。
    bool enable = view_as<bool>(GetNativeCell(1));

    // 重复设置不触发额外的 CVar 写入。
    if (g_bSuperMode != enable)
    {
        g_bSuperMode = enable;

        if (enable)
        {
            // 超级模式固定使用 24 个槽位。
            g_cvMaxSI.SetInt(24);
            PrintToChatAll("\x04[Sion]\x01 外部指令：已激活 \x03[超多特模式] \x01(上限自动锁定: \x0324\x01)");
            PrintToChatAll("\x04[配置]\x01 严格限制：25%%牛 20%%HT 20%%猴 15%%舌");
        }
        else {
            // 退出后恢复插件默认上限。
            g_cvMaxSI.SetInt(8);
            PrintToChatAll("\x04[Sion]\x01 外部指令：已关闭超多特模式 \x01(上限恢复: \x038\x01)");
        }

        UnlockLimits();    // 先改插件值，再同步引擎 CVar。
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
    // 避免零间隔导致定时器持续触发。
    if (cooldown < 1.0) cooldown = 0.1;

    g_cvHungerCooldown.SetFloat(cooldown);
    g_bUserOverride_MobCD = true;
    g_fUserVal_MobCD      = cooldown;
    PrintToChatAll("\x04[Sion]\x01 外部指令: 补货冷却已更新为 \x03%.1f秒", cooldown);
    return 1;
}

public int Native_SetTankControl(Handle plugin, int numParams)
{
    bool enable = view_as<bool>(GetNativeCell(1));
    g_cvEnableTankControl.SetInt(enable ? 1 : 0);
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

// Nav 缓存与分桶

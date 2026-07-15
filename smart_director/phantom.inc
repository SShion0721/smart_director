public Action Hook_NormalSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
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

    // 找一个倒霉蛋
    int victim      = SD_GetBestStrategicTarget();
    if (victim <= 0) victim = SD_GetRandomSurvivor();    // 如果没有最佳目标，就随便抽一个存活的

    // 如果有人活着，就播放幻听
    if (victim > 0)
    {
        SD_PlayPhantomSound(victim);
    }

    // 每次触发后按当前区间重新采样下一次时间。
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

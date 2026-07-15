static void SaveBucketsToCache()
{
    if (!bNavCacheEnable || !g_BucketsReady) return;

    MakeBucketCachePath();

    KeyValues kv = new KeyValues("BucketsCache");
    kv.SetString("version", BUCKET_CACHE_VER);

    char map[64];
    GetCurrentMap(map, sizeof map);
    kv.SetString("map", map);

    // 使用缓存
    EnsureNavAreasCache();
    int areaCount = g_NavAreasCacheCount;

    kv.SetNum("area_count", areaCount);
    kv.SetFloat("max_flow", L4D2Direct_GetMapMaxFlowDistance());
    kv.SetFloat("vsboss_buffer", VsBossFlowBuffer.FloatValue);
    kv.SetNum("map_invalid", bNavBucketMapInvalid ? 1 : 0);
    kv.SetFloat("assign_radius", fNavBucketAssignRadius);

    // 桶 Z 范围
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

    // areas
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

    // 传入的是“距离”而非比例：做 NaN/负数/越界钳位
    float d = flowDist;
    if (!(d >= 0.0)) d = 0.0;    // NaN/负数 → 0
    if (d > maxd) d = maxd;    // 距离上限

    // 按距离口径叠加 BossBuffer（也是距离）
    float prox = d + VsBossFlowBuffer.FloatValue;
    if (!(prox >= 0.0)) prox = 0.0;
    if (prox > maxd) prox = maxd;

    return RoundToNearest((prox / maxd) * 100.0);    // → 0..100
}

// 采样 NavArea 的“几何中心近似 + 高度统计”
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

    // 使用缓存
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

    // 影响分桶的运行参数（变了就作废）
    float bufCur        = VsBossFlowBuffer.FloatValue;
    float bufCached     = kv.GetFloat("vsboss_buffer", 0.0);
    int   mapInvalidCur = bNavBucketMapInvalid ? 1 : 0;
    int   mapInvalidCac = kv.GetNum("map_invalid", 1);
    float assignRcur    = fNavBucketAssignRadius;
    float assignRcac    = kv.GetFloat("assign_radius", 0.0);

    if (FloatAbs(bufCur - bufCached) > 0.01 || mapInvalidCur != mapInvalidCac || FloatAbs(assignRcur - assignRcac) > 0.5)
    {
        delete kv;
        return false;
    }

    // 清理并初始化容器
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

    // 桶 Z 范围
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

    // areas
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
// 返回 true 表示找到至少一名有效、生还且有坐标的生还者；outMinZ 为他们脚底 Z 的最小值
static void OnFlowBufferChanged(ConVar convar, const char[] ov, const char[] nv)
{
    // Flow 百分比变化会影响分桶 → 重建
    RebuildNavBuckets();
}
static void RebuildNavBuckets()
{
    BuildNavBuckets();
}


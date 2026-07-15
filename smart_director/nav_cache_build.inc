static void ClearNavBuckets()
{
    for (int i = 0; i < FLOW_BUCKETS; i++)
    {
        if (g_FlowBuckets[i] != null)
        {
            delete g_FlowBuckets[i];
            g_FlowBuckets[i] = null;
        }
        g_BucketMinZ[i] = 0.0;
        g_BucketMaxZ[i] = 0.0;
    }

    if (g_AreaZCore != null)
    {
        delete g_AreaZCore;
        g_AreaZCore = null;
    }
    if (g_AreaZMin != null)
    {
        delete g_AreaZMin;
        g_AreaZMin = null;
    }
    if (g_AreaZMax != null)
    {
        delete g_AreaZMax;
        g_AreaZMax = null;
    }
    if (g_AreaCX != null)
    {
        delete g_AreaCX;
        g_AreaCX = null;
    }
    if (g_AreaCY != null)
    {
        delete g_AreaCY;
        g_AreaCY = null;
    }
    if (g_AreaPct != null)
    {
        delete g_AreaPct;
        g_AreaPct = null;
    }
}
static void BuildNavIdIndexMap()
{
    if (g_NavIdToIndex != null)
    {
        delete g_NavIdToIndex;
        g_NavIdToIndex = null;
    }
    g_NavIdToIndex = new StringMap();

    EnsureNavAreasCache();    // 确保缓存存在

    for (int i = 0; i < g_NavAreasCacheCount; i++)
    {
        Address area  = g_AllNavAreasCache.Get(i);
        int     navid = L4D_GetNavAreaID(area);
        if (navid < 0) continue;

        char key[16];
        IntToString(navid, key, sizeof key);
        g_NavIdToIndex.SetValue(key, view_as<any>(i));
    }
}
stock void EnsureNavAreasCache()
{
    if (g_AllNavAreasCache == null)
    {
        g_AllNavAreasCache = new ArrayList();
        L4D_GetAllNavAreas(g_AllNavAreasCache);
        g_NavAreasCacheCount = g_AllNavAreasCache.Length;
    }
}
static void BuildNavBuckets()
{
    g_fMapMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    // 1) 尝试读缓存（成功就直接返回）
    if (TryLoadBucketsFromCache())
        return;

    // 2) 清理旧数据、准备索引与缓存
    ClearNavBuckets();
    BuildNavIdIndexMap();
    EnsureNavAreasCache();

    int   iAreaCount      = g_NavAreasCacheCount;
    float fMapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();

    // 3) 初始化 per-area / per-bucket 容器
    g_AreaZCore           = new ArrayList();
    g_AreaZMin            = new ArrayList();
    g_AreaZMax            = new ArrayList();
    g_AreaCX              = new ArrayList();
    g_AreaCY              = new ArrayList();
    g_AreaPct             = new ArrayList();

    for (int i = 0; i < iAreaCount; i++)
    {
        g_AreaZCore.Push(0.0);
        g_AreaZMin.Push(0.0);
        g_AreaZMax.Push(0.0);
        g_AreaCX.Push(0.0);
        g_AreaCY.Push(0.0);
        g_AreaPct.Push(-1);    // 1 = 未归桶/坏flow
    }

    for (int b = 0; b < FLOW_BUCKETS; b++)
    {
        g_FlowBuckets[b] = null;
        g_BucketMinZ[b]  = 1.0e9;
        g_BucketMaxZ[b]  = -1.0e9;
    }

    ArrayList badIdxs   = new ArrayList();
    ArrayList validIdxs = new ArrayList();

    // 4) 第一遍：采样中心/高度，正常 flow 直接入桶
    for (int i = 0; i < iAreaCount; i++)
    {
        Address areaAddr = g_AllNavAreasCache.Get(i);
        if (areaAddr == Address_Null) continue;

        NavArea pArea = view_as<NavArea>(areaAddr);

        float   cx, cy, zAvg, zMin, zMax;
        SampleAreaCenterAndZ(areaAddr, cx, cy, zAvg, zMin, zMax, 3);
        g_AreaCX.Set(i, cx);
        g_AreaCY.Set(i, cy);
        g_AreaZCore.Set(i, zAvg);
        g_AreaZMin.Set(i, zMin);
        g_AreaZMax.Set(i, zMax);

        // 原始 flow 到百分比（无效则进坏列表）
        float fFlow  = pArea.GetFlow();
        bool  flowOK = (fFlow >= 0.0 && fFlow <= fMapMaxFlowDist);

        if (flowOK)
        {
            int percent = FlowDistanceToPercent(fFlow);
            if (percent < 0) percent = 0;
            if (percent > 100) percent = 100;

            if (g_FlowBuckets[percent] == null)
                g_FlowBuckets[percent] = new ArrayList();
            g_FlowBuckets[percent].Push(i);

            if (zMin < g_BucketMinZ[percent]) g_BucketMinZ[percent] = zMin;
            if (zMax > g_BucketMaxZ[percent]) g_BucketMaxZ[percent] = zMax;

            g_AreaPct.Set(i, percent);
            validIdxs.Push(i);
        }
        else
        {
            badIdxs.Push(i);
        }
    }

    // Debug_Print("[BUCKET] pass1 done: valid=%d bad=%d skipped=%d took=%.3fs",

    // 5) 第二遍：把坏 flow 的区域映射到最近“有效桶”（二维栅格 + 成本/时间保护）
    if (validIdxs.Length > 0 && badIdxs.Length > 0)
    {
        // 1 估算成本与时间预算
        int         B = badIdxs.Length, V = validIdxs.Length;
        float       estCostM    = float(B) * float(V) / 1.0e6;
        const float hardCostM   = 5.0;    // ≈500万配对：超过则跳过映射
        const float timeBudgetS = 0.60;    // 总时间预算：>0.6s 就中止映射

        float       t1          = GetEngineTime();
        if (estCostM > hardCostM)
        {
        }
        else
        {
            // 2 构建“有效区”二维栅格
            const float cell   = 2000.0;    // 栅格边长（可按地图尺度调整）
            float       radius = fNavBucketAssignRadius;    // 0=不限
            if (radius < 0.0) radius = 0.0;

            StringMap cellMap    = new StringMap();
            ArrayList ownedLists = new ArrayList();    // 收尾 delete

            for (int i = 0; i < V; i++)
            {
                int   vidx = validIdxs.Get(i);
                float vx   = view_as<float>(g_AreaCX.Get(vidx));
                float vy   = view_as<float>(g_AreaCY.Get(vidx));
                int   cx   = RoundToFloor(vx / cell);
                int   cy   = RoundToFloor(vy / cell);

                char  key[32];
                Format(key, sizeof key, "%d,%d", cx, cy);

                any       h;
                ArrayList lst;
                if (!cellMap.GetValue(key, h))
                {
                    lst = new ArrayList();
                    ownedLists.Push(lst);
                    cellMap.SetValue(key, view_as<any>(lst));
                }
                else
                {
                    lst = view_as<ArrayList>(h);
                }
                lst.Push(vidx);
            }

            // 3 邻格扩环检索参数
            int maxLayer = (radius > 0.1) ? RoundToCeil(radius / cell) : 6;
            if (maxLayer < 0) maxLayer = 0;
            if (maxLayer > 48) maxLayer = 48;
            float r2     = (radius > 0.1) ? (radius * radius) : -1.0;

            int   mapped = 0, dropped = 0;

            // 4 对每个坏区做邻格扩环搜索
            for (int bi = 0; bi < B; bi++)
            {
                // 时间预算：每 1024 个检查一次
                if ((bi & 1023) == 0)
                {
                    float el = GetEngineTime() - t1;
                    if (el > timeBudgetS)
                    {
                        // Debug_Print("[BUCKET] pass2 ABORT(time): bi=%d/%d mapped=%d dropped=%d el=%.3fs",
                        break;
                    }
                }

                int   aidx   = badIdxs.Get(bi);
                float ax     = view_as<float>(g_AreaCX.Get(aidx));
                float ay     = view_as<float>(g_AreaCY.Get(aidx));
                int   acx    = RoundToFloor(ax / cell);
                int   acy    = RoundToFloor(ay / cell);

                float bestD2 = 1.0e20;
                int   bestV  = -1;

                // 扩环：layer=0..maxLayer（只扫 ring 外框，避免 O(layer^2)）
                for (int layer = 0; layer <= maxLayer; layer++)
                {
                    bool foundThisRing = false;
                    int  minX = acx - layer, maxX = acx + layer;
                    int  minY = acy - layer, maxY = acy + layer;

                    for (int cy = minY; cy <= maxY; cy++)
                    {
                        for (int cx = minX; cx <= maxX; cx++)
                        {
                            bool onEdge = (cx == minX || cx == maxX || cy == minY || cy == maxY);
                            if (!onEdge) continue;

                            char key[32];
                            Format(key, sizeof key, "%d,%d", cx, cy);

                            any h;
                            if (!cellMap.GetValue(key, h)) continue;
                            ArrayList lst = view_as<ArrayList>(h);

                            for (int k = 0; k < lst.Length; k++)
                            {
                                int   vidx = lst.Get(k);
                                float vx   = view_as<float>(g_AreaCX.Get(vidx));
                                float vy   = view_as<float>(g_AreaCY.Get(vidx));
                                float dx = ax - vx, dy = ay - vy;
                                float d2 = dx * dx + dy * dy;

                                if (r2 > 0.0 && d2 > r2) continue;
                                if (d2 < bestD2)
                                {
                                    bestD2        = d2;
                                    bestV         = vidx;
                                    foundThisRing = true;
                                }
                            }
                        }
                    }

                    if (foundThisRing)
                        break;
                }

                if (bestV != -1)
                {
                    int percent = view_as<int>(g_AreaPct.Get(bestV));
                    if (percent < 0) percent = 0;
                    if (percent > 100) percent = 100;

                    if (g_FlowBuckets[percent] == null)
                        g_FlowBuckets[percent] = new ArrayList();
                    g_FlowBuckets[percent].Push(aidx);

                    float zmin = view_as<float>(g_AreaZMin.Get(aidx));
                    float zmax = view_as<float>(g_AreaZMax.Get(aidx));
                    if (zmin < g_BucketMinZ[percent]) g_BucketMinZ[percent] = zmin;
                    if (zmax > g_BucketMaxZ[percent]) g_BucketMaxZ[percent] = zmax;

                    g_AreaPct.Set(aidx, percent);
                    mapped++;
                }
                else
                {
                    dropped++;
                }

            }

            // Debug_Print("[BUCKET] pass2 %s: B=%d V=%d mapped=%d dropped=%d took=%.3fs",
            // aborted ? "done(partial)" : "done",

            // 5 释放 cellMap 内存
            for (int i = 0; i < ownedLists.Length; i++)
            {
                ArrayList lst = ownedLists.Get(i);
                if (lst != null) delete lst;
            }
            delete ownedLists;
            delete cellMap;
        }
    }
    else
    {
        // Debug_Print("[BUCKET] pass2 skip: mapInvalid=%d valid=%d bad=%d",
    }

    // 6) 完成：标记就绪 & 存缓存
    g_BucketsReady = true;

    SaveBucketsToCache();    // 缓存开启时写入地图对应的 KV 文件。
}

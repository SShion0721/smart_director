# Smart Director

基于 CPU NNUE 神经网络的 Left 4 Dead 2 特感导演。网络结合生还者状态、地图进度、特感类型和候选位置，为生成点排序。

## 神经网络选点

核心想法是让网络学习“当前局面下，哪里更值得进攻”。Director 先决定特感类型，Nav 提供候选位置，NNUE 批量评分，再按分数从高到低尝试生成。

默认网络为 `106 → 256 → 32 → 1`。同批候选共享大部分局面信息，CPU 后端复用第一层累加结果，只为各候选补充位置差异；批内去重和评分缓存进一步减少重复计算。

碰撞、视线和路径负责判断位置能否生成，NNUE 负责判断优先尝试哪里。这样可以先对一批候选做低成本评分，再按需执行引擎查询。学习目标是提高进攻收益，例如伤害、有效控制和阻止生还者推进。

## 当前不足与后续方向

目前主要完成了 NNUE 的模型加载、批量评分和生成接入。因为没时间，训练管线和训练数据采集插件还没有写，也没有随仓库提供训练好的权重。

- 先从对抗比赛数据和采集插件积累训练集，学习每一波的生成位置、造成的伤害，以及阻止生还者推进的收益；之后再加入终局监督。
- 106 维输入是第一版设计，不是最优特征。血量、控制、阵形和位置的表示还可以调整，也需要重新考虑哪些输入适合增量更新。
- 网络可以尝试扩大到 `106 → 512 → 64 → 1`，比较容量增加后的效果和延迟。
- CPU 后端可以增加 AVX/AVX2 等 SIMD 优化，加速特征累加和 dense 层，并保留普通实现以兼容不同服务器 CPU。

训练目标、数据采集与输入设计见 [NNUE.md](NNUE.md)。

## 功能

- 使用 Nav Flow 分桶搜索生成区域。
- 根据生还者位置、血量和控制状态选择进攻目标。
- 通过生成队列、特感配额和补充冷却控制刷怪节奏。
- 提供六档难度、Tank 控制、尸潮联动和幻听音效。
- 清理落后或长时间停滞的特感，为新生成的特感保留保护期。
- 使用 CPU NNUE 批量评估普通特感的候选位置，依次检查碰撞、视线和路径后生成；候选不可用时交给引擎选点。

## 版本

| 分支 | 选点方式 | 额外依赖 |
| --- | --- | --- |
| `main` | NNUE 候选排序与引擎选点 | NNUE 扩展、模型权重 |
| `stable` | Nav 规则选点与引擎选点 | 无 |

## 编译与安装

插件需要 SourceMod 1.12、SDKTools、SDKHooks、Left4DHooks、SourceScramble，以及 `gamedata/function_data.txt` 中的 `CDirector::GetMaxPlayerZombies` 补丁配置。

```bash
mkdir -p compiled
"<SourceMod scripting>/spcomp.exe" smart_director.sp \
  -i"include" -i"<SourceMod scripting>/include" \
  -o"compiled/smart_director.smx"

cmake -S extension -B extension/build \
  -G "Visual Studio 17 2022" -A Win32 \
  -DSOURCEMOD_ROOT="<SourceMod 源码>"
cmake --build extension/build --config Release
```

以上命令使用 Windows Git Bash。扩展使用 Visual Studio 2022、CMake 和已初始化子模块的 SourceMod 源码，默认构建 Win32。插件依赖的 include 放在 SourceMod scripting 目录的 `include` 中。

将以下文件放入服务端：

| 文件 | 目标目录 |
| --- | --- |
| `gamedata/function_data.txt` | `addons/sourcemod/gamedata/` |
| `compiled/smart_director.smx` | `addons/sourcemod/plugins/` |
| `extension/build/Release/sd_nnue.ext.dll` | `addons/sourcemod/extensions/` |
| `nnue_weights.bin` | `addons/sourcemod/data/smart_director/` |

## 常用配置

| 参数 | 默认值 | 作用 |
| --- | --- | --- |
| `sd_max_si` | 8 | 特感数量上限 |
| `sd_dist_min` / `sd_dist_max` | 150 / 350 | 生成距离范围 |
| `sd_hunger_cooldown` | 5 | 特感补充冷却，秒 |
| `sd_difficulty_tier` | 2 | 难度档位，1–6 |
| `sd_check_vis` | 1 | 0 关闭视线检测，1 检查目标，2 检查全队 |
| `sd_cull_dist` | 1000 | 落后特感的清理距离 |
| `sd_enable_tank_control` | 1 | 接管 Tank 生成 |
| `sd_silent_si` | 0 | 屏蔽特感叫声 |

管理员可使用 `sm_sd_force_spawn`、`sm_sd_force_tank` 和 `sm_sd_rebuild_nav` 调试生成，使用 `sm_sd_nnue_status` 查看 NNUE 状态，使用 `sm_sd_nnue_reload` 重载模型。

NNUE 配置与模型格式见 [NNUE.md](NNUE.md)。

## 致谢与许可

NavArea 访问、Nav Flow 分桶和基础选点代码直接取自 [CompetitiveWithAnne 的 infected_control.sp](https://github.com/fantasylidong/CompetitiveWithAnne/blob/d68cca7ad2465539a3bf4105aa34aebab9c7f633/addons/sourcemod/scripting/AnneHappy/infected_control.sp)。我自己写的那版 bug 太多，懒得继续 debug，就直接用了他们的实现，再按本项目的生成流程作了调整。

感谢原作者及贡献者东、Caibiii、夜羽真白、Paimon-Kawaii、fdxx。相关代码沿用上游 GPL-3.0 许可，本项目同样采用 GPL-3.0，完整许可见 [LICENSE](LICENSE)。

# Smart Director stable

Left 4 Dead 2 特感导演插件，使用 Nav Flow 和规则选点管理特感进攻。

## 功能

- 根据队伍状态和地图进度选择进攻目标与生成区域。
- 使用生成队列、特感配额、补充冷却和半数生成限制安排刷怪。
- 检查生成距离、视线、碰撞和 Nav 路径，支持引擎选点回退。
- 提供六档难度、Tank 控制、尸潮联动和幻听音效。
- 自动清理落后或停滞的特感，为新生成的特感保留保护期。
- 提供 Nav 缓存、Flow 可视化和管理员调试命令。

## 编译与安装

需要 SourceMod 1.12、SDKTools、SDKHooks、Left4DHooks、SourceScramble，以及 `gamedata/function_data.txt` 中的补丁配置。

```bash
"<SourceMod scripting>/spcomp.exe" smart_director.sp \
  -i"<SourceMod scripting>/include" -o"smart_director.smx"
```

将 `smart_director.smx` 放入服务端 `addons/sourcemod/plugins/`，将 `gamedata/function_data.txt` 放入 `addons/sourcemod/gamedata/`。

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

管理员命令包括 `sm_sd_force_spawn`、`sm_sd_force_tank`、`sm_sd_rebuild_nav`、`sm_nd` 和 `sm_nd_flow`。

## 版本

`stable` 使用纯规则选点，无需模型或 NNUE 扩展；`main` 提供 CPU NNUE 候选排序。

## 致谢与许可

NavArea 访问、Nav Flow 分桶和基础选点代码直接取自 [CompetitiveWithAnne 的 infected_control.sp](https://github.com/fantasylidong/CompetitiveWithAnne/blob/d68cca7ad2465539a3bf4105aa34aebab9c7f633/addons/sourcemod/scripting/AnneHappy/infected_control.sp)。我自己写的那版 bug 太多，懒得继续 debug，就直接用了他们的实现，再按本项目的生成流程作了调整。

感谢原作者及贡献者东、Caibiii、夜羽真白、Paimon-Kawaii、fdxx。相关代码沿用上游 GPL-3.0 许可，本项目同样采用 GPL-3.0，完整许可见 [LICENSE](LICENSE)。

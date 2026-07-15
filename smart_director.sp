/**
 * Smart Director
 *
 * 插件根据生还者进度、队伍状态和 Nav 数据控制特感生成。
 * 运行流程分为四个阶段：
 * 1. 缓存玩家状态与地图 Nav 信息；
 * 2. 根据当前压力和特感配额生成队列；
 * 3. 对候选生成位置执行距离、可见性、地形和进度约束检查；
 * 4. 执行生成，并同步在途数量、幽灵占位和调试记录。
 *
 * 当前规则系统仍是行为基线。实验性评估器必须保留该基线作为回退路径，
 * 不能绕过合法性检查、配额限制和生成失败后的状态恢复。
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <sourcescramble>    // GameData 与 MemoryPatch 接口
#pragma semicolon 1
#pragma newdecls required

// 模块按依赖关系排列。后续模块可以调用前面模块定义的状态和工具函数。
#include "smart_director/config.inc"
#include "smart_director/api.inc"
#include "smart_director/nav_cache_build.inc"
#include "smart_director/nav_cache_io.inc"
#include "smart_director/nav_helpers.inc"
#include "smart_director/lifecycle_setup.inc"
#include "smart_director/lifecycle_run.inc"
#include "smart_director/state_spawn.inc"
#include "smart_director/waves_debug.inc"
#include "smart_director/logic_admin.inc"
#include "smart_director/phantom.inc"

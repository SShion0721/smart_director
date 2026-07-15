/**
 * Smart Director
 *
 * 目标很直接：按队伍进度和状态控制特感生成，同时避免刷点不可达、队列超额和重复占位。
 * 这份代码只保留当前实际运行的路径；旧实现不放在注释里，历史直接交给 Git。
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <sourcescramble>    // GameData 与 MemoryPatch 依赖
#pragma semicolon 1
#pragma newdecls required

// 实现按职责拆开；include 顺序就是原来的执行顺序。
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

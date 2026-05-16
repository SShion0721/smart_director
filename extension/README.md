# sd_nnue 扩展

为 Smart Director 提供 CPU NNUE 批量评分、批内去重和评分缓存。扩展注册 `sd_nnue` 库，接口声明位于 `include/sd_nnue.inc`。

## 构建

需要 Visual Studio 2022 C++、CMake 3.24+ 和 SourceMod 源码。先初始化源码中的 `sourcepawn`、`public/amtl` 子模块，再从仓库根目录使用 Windows Git Bash 执行：

```bash
cmake -S extension -B extension/build \
  -G "Visual Studio 17 2022" -A Win32 \
  -DSOURCEMOD_ROOT="<SourceMod 源码>"
cmake --build extension/build --config Release
```

默认生成 Win32 `extension/build/Release/sd_nnue.ext.dll`。将 DLL 放入服务端 `addons/sourcemod/extensions/`，模型放入 `addons/sourcemod/data/smart_director/nnue_weights.bin`。

## 使用

启动服务端后，用 `sm_sd_nnue_status` 查看模型和缓存状态，用 `sm_sd_nnue_reload` 重载权重。缓存大小通过 `sd_nnue_cache_mb` 配置。

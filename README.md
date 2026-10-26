# EasyGPUUnlock

运行环境：Windows 10 2004+ / Windows 11 AMD64/x64，需管理员权限、测试签名模式、关闭 HVCI（内存完整性）。型号需与 [gpu-profiles.json](gpu-profiles.json) 中的精确 PCI ID 对应，才能生效。

程序会检测当前环境并备份 NVIDIA 驱动，然后在设备实例中解绑目标 GPU 的 NV 驱动，并绑定自有 KMDF 驱动。内核层会执行 FWSEC / V67、SS0/SS1 设置以及 FLR（Function Level Reset）等操作，进而解锁 Ampere/Ada 系列 GPU 的受限功能。

## 效果

EasyGPUUnlock 0.1.1 / RTX 3080 10GB / NVIDIA 610.88 / BF16_FP32 实测：

| 项目 | 解锁前 (TFLOPS) | 解锁后 (TFLOPS) | 提升 |
| :--- | :--- | :--- | :--- |
| BF16 MMA | 68.19 | 134.48 | +97.22% |
| BF16 GEMM (4096×4096) | 62.93 | 104.35 | +65.82% |

恢复 NV 驱动后，五种 GEMM 模式的正确性检查均通过。

## 用法

下载 [最新 Release](https://github.com/eastmoe/EasyGPUUnlock/releases/latest)，完整解压 ZIP 后，双击 `start.bat` 并确认 UAC 提权。多卡时按提示选择目标显卡；Experimental 型号需先选择对应配置。

在解压目录打开 PowerShell：

```powershell
# 读取环境与显卡状态
.\start.bat -Action Status

# 开启测试签名，执行后需手动重启
.\start.bat -Action EnableTestMode

# 根据备份还原 NV 驱动
.\start.bat -Action Restore
```

重启后再次运行 Status，若 `TestModeActive=True`，则表示测试签名已生效。

备份与恢复记录位于 `%ProgramData%\EasyGPUUnlock`。若出现固件 / DMA 断电提示，请先关机断电，再开机并重新运行 `Restore`。

## 上游项目

- [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)：Ampere 解锁逻辑。
- [JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada)：Ada 解锁逻辑与固件生成工具。
- [eastmoe/cmp170hx-windows-driver](https://github.com/eastmoe/cmp170hx-windows-driver)：Windows 独占设备接管、HAL DMA 及同步 PCI 总线复位实现参考。

# EasyGPUUnlock

运行配置：Windows 10 2004+ / Windows 11 AMD64/x64、管理员权限、测试签名模式、关闭 HVCI（内存完整性）。型号按 [gpu-profiles.json](gpu-profiles.json) 中的精确 PCI ID 选择：52 个 RTX 30 Ampere ID、17 个 RTX 40 Ada ID。驱动使用 `CN=StarMoon` 自签名测试证书，解锁时导入本机 Root / TrustedPublisher。

程序检测环境并备份 NVIDIA 驱动，按设备实例解绑目标 GPU 的 NV 驱动，再绑定自有 KMDF 驱动。内核执行 FWSEC / V67、SS0/SS1 设置及 FLR（Function Level Reset），校验解锁结果和资源清理状态，随后还原原 NVIDIA 驱动。

## 效果

EasyGPUUnlock 0.1.1 / RTX 3080 10GB / NVIDIA 610.88 / BF16_FP32 实测：

| 项目 | 解锁前 (TFLOPS) | 解锁后 (TFLOPS) | 提升 |
| :--- | :--- | :--- | :--- |
| BF16 MMA | 68.19 | 134.48 | +97.22% |
| BF16 GEMM (4096×4096) | 62.93 | 104.35 | +65.82% |

恢复 NV 驱动后，五种 GEMM 模式正确性检查通过。

## 用法

下载 [最新 Release](https://github.com/eastmoe/EasyGPUUnlock/releases/latest)，完整解压 ZIP，双击 `start.bat` 并确认 UAC 提权。多卡按提示选卡，Experimental 型号通过选择确认。命令行指定实验型号时，同时传完整 `-InstanceId` 和 `-AllowExperimental`。

在解压目录打开 PowerShell：

```powershell
# 读取环境与显卡状态
.\start.bat -Action Status

# 开启测试签名，执行后手动重启
.\start.bat -Action EnableTestMode

# 根据备份还原 NV 驱动
.\start.bat -Action Restore
```

重启后运行 Status，`TestModeActive=True` 表示测试签名已生效。

备份和恢复记录位于 `%ProgramData%\EasyGPUUnlock`。收到固件 / DMA 断电提示时，先关机断电再开机，再运行 `Restore`。

## 上游项目

- [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)：Ampere 解锁逻辑。
- [JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada)：Ada 解锁逻辑与固件生成工具。
- [eastmoe/cmp170hx-windows-driver](https://github.com/eastmoe/cmp170hx-windows-driver)：Windows 独占设备接管、HAL DMA 及同步 PCI 总线复位实现参考。

# Intel Arc B580 · 27B · 32K 上下文（Vulkan 路径）

给没有 NVIDIA 卡的人用的一条**并列路径**：同一批三值 27B 权重（PTQ1_0 GGUF），
跑在 Intel Arc 的 **Vulkan 后端** 上，用本仓库同一套 `scripts\serve.ps1` 契约，
所以 **DSH 的本地模型开关插件可以直接认它**（左键启停、右键切模型）。

> 这个目录**不改变**仓库原有的 RTX 50 / NInfer / 73K 主路径，只是新增一条 Intel 分支。
> 原有 `install.bat` / `start.bat` / `scripts\serve.ps1` 一行都没动。

---

## 先说清楚能做到什么、做不到什么

在 **Arc B580 12 GB** 上实测（Windows 11，驱动 32.0.101.9150，Vulkan，KV `q8_0`）：

| 项 | 实测 |
|---|---|
| 模型 | `Ternary-Bonsai-2-27B-PTQ1_0.gguf`（5.53 GiB，1.75 bpw 三值） |
| 引擎 | llama.cpp（Vulkan 后端，含 Intel Xe 的 FA 内核与 coopmat tile 修复） |
| 上下文 | **32768 可用**（KV 1088 MiB + 模型 5395 MiB，显存不是瓶颈） |
| 短提示解码 | **31–33 t/s**（32K 上下文下）；16K 上下文下最高测到 36.7 t/s |
| 长提示预填充 | 20K 提示 361 t/s；28K 提示 342 t/s；30K 提示 339 t/s |
| 12K 提示预填充 | 414 t/s |
| **73,728 上下文** | **加载得起来，但长提示会崩**（见下） |

**已经撞到的两个硬墙，别当成配置问题：**

1. **提示长度接近上下文上限时会崩进程**：32K 上下文 + 31.5K token 的提示，两次实测都是进程直接消失（日志里没有任何报错，典型驱动复位）。
2. **71K token 的提示在 72K 上下文下，跑到约 18K token 处崩**（同样无报错）。同期 20K/28K/30K 提示在 32K 上下文下都正常。

⇒ 所以这条路径的**可用上限是 32K 上下文 / 30K 以内提示**。本仓库主路径宣称的 73K 是靠 **KVMem 的 KV 虚拟化（KV 落 RAM/SSD）** 实现的，那是 NInfer 引擎的能力，llama.cpp 的 Vulkan 后端没有对应机制，显存放得下也不等于跑得稳。

---

## 为什么不是「把 serve.ps1 改个参数」

`serve.ps1` 的参数是给 NInfer 引擎的，Intel 这条路径的引擎是 `llama-server.exe`，参数集完全不同
（`-ngl`、`-ctk/-ctv`、`-np` 等）。所以这里给了**一份新的 `scripts\serve.ps1`**，
但**保持了 DSH 插件依赖的三条契约**：

| 契约 | 本脚本 |
|---|---|
| 文件名是 `scripts\serve.ps1` | ✅ |
| 上下文参数名是 `-Context <tokens>`（不是 `-Ctx`） | ✅ |
| 脚本里 `$Port` 有默认值（插件靠它匹配 provider） | ✅ 默认 `18080` |

---

## 用法

```text
① 把 Vulkan 版 llama.cpp 解压到 <本目录>\bin\        （里面要有 llama-server.exe）
② 把 *.gguf 放进 <本目录>\model\                     （建议 Ternary-Bonsai-2-27B-PTQ1_0.gguf）
③ 双击 start.bat                                      （或 start.bat -Context 32768）
```

- `start.bat` —— 后台起服务，等 `/health` 变 ok 再返回，打印 `http://127.0.0.1:18080/v1`
- `status.bat` —— 看 pid / 端口 / health / `/v1/models`
- `stop.bat` —— 只杀自己 pid 文件里那个进程，不会误杀别的本地模型

可选参数（都透传给 `scripts\serve.ps1`）：

```powershell
powershell -File scripts\serve.ps1 -Context 32768          # 上下文
powershell -File scripts\serve.ps1 -Port 18080             # 端口
powershell -File scripts\serve.ps1 -Model D:\x\y.gguf      # 指定权重
powershell -File scripts\serve.ps1 -BinDir D:\llama-vk     # 指定引擎目录
powershell -File scripts\serve.ps1 -Foreground             # 前台跑（排错用）
```

**接 DSH**：把 provider 指到 `http://127.0.0.1:18080/v1`（OpenAI 兼容），然后在插件右键菜单里选中这个部署夹即可。

---

## 显存预算（自己算也能验证）

| 上下文 | KV（q8_0） | 模型 | compute buffer | 合计 |
|---|---|---|---|---|
| 16384 | 544 MiB | 5395 MiB | ~170 MiB | ~6.1 GiB |
| 32768 | 1088 MiB | 5395 MiB | ~174 MiB | ~6.7 GiB |
| 73728 | ~2448 MiB | 5395 MiB | — | ~8 GiB（**能装，但长提示会崩**） |

12 GB 卡装得下 73K —— 崩的原因是内核/驱动在长序列上的稳定性，不是显存不够。这一点很容易误判，所以单列出来。

---

## 已验证 / 未验证

- `PASS`：`start.bat` → `/health` ok、`/v1/models` 返回模型、`status.bat` / `stop.bat` 正常；32K 上下文下 30K 提示跑通。
- `PENDING`：73K 上下文的长提示（必崩，未找到绕过办法）；q4_0 KV（实测比 q8_0 慢很多，未采用）。
- 机器本身有间歇性抖动（同一二进制偶尔从 33 t/s 掉到 3 t/s，下一轮又恢复），做 A/B 必须交叉重复，不要单次定论。

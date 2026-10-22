# Bonsai 27B · 72K 本地服务（可复现部署包 v1.3）

一台 12 GB 显存的笔记本（RTX 5070 Ti Laptop / 16 GB 内存）上，跑一个 **27B 参数、72,768 token 上下文**的本地大模型，并接进 DeepSeek Harness 当日常模型用。

- **首次部署**：双击 `install.bat`，自动下载 10.4 GB、校验、解压、启动。
- **以后使用**：双击 `start.bat` / `stop.bat` / `status.bat`。
- **接进 DSH**：装一次插件（`dsh-local-model-toggle-plugin-0.6.0.zip`），之后左下角一个开关就能启停。
- **不需要** Python、CUDA Toolkit、CMake、Visual Studio，也不需要编译。

| 项目 | 值 |
| --- | --- |
| 模型 | Ternary Bonsai 2 27B（三进制权重，PTQ1_0） |
| 权重文件 | `Ternary-Bonsai-2-27B-ninfer-v3.ninfer`，9,520,051,456 字节（8.87 GiB） |
| 推理引擎 | KVMem v0.18.0 · NInfer 后端 · Windows RTX 50 系（sm_120a） |
| 上下文 | 73,728 tokens（rk4v4 量化 KV） |
| 显存占用 | 约 10.4–10.6 GB |
| 速度 | 预填充 564–679 tok/s，解码 57–66 tok/s |
| 端口 / 模型名 | `http://127.0.0.1:18200/v1` · `bonsai2-27b` |
| **API Key** | 默认 `sk-171212e1b4a08d12xh2131234356647yu`，首次 install 时写进 `api-key.txt` |

---

## 一、怎么装（从零开始）

```
Bonsai-27B-72K\
   install.bat      ← 首次运行这个
   start.bat        ← 以后启动
   stop.bat         ← 停止
   status.bat       ← 看状态
```

**步骤**：

1. 把整个文件夹放到一个**剩余空间 ≥ 22 GB** 的盘上（路径可以有中文和空格）。
2. 双击 `install.bat`。
3. 等它跑完（首次约 10–30 分钟，取决于网速；断了重跑会**续传**）。
4. 看到 `[+] 完成` 就好了，浏览器会自动打开 Web UI。

`install.bat` 做了什么：

| 步骤 | 内容 | 失败时会怎样 |
| --- | --- | --- |
| 0 | 查 Windows 版本、curl、显卡（`compute_cap=12.0`）、磁盘、VC++ 运行库 | 缺 VC++ 会自动下载安装（弹一次 UAC）；显卡不是 50 系会直接停下并说明 |
| 1 | 测速挑源 → 下载引擎包 900 MB → 校验 SHA256 → 解压到 `engine\` | 校验不过会删掉重下；某个源卡住会自动换源 |
| 2 | 下载权重 9.5 GB → 校验 SHA256 → 放 `model\` | 同上 |
| 3 | 没有 `api-key.txt` 就写入默认密钥 | — |
| 4 | 调 `serve.ps1` 启动服务，等 `/health` 200 | 打印引擎日志最后 12 行 |

**可复现性说明**：引擎和权重是从公开地址下载的，脚本里写死了 SHA256，
任何一个字节不对就拒绝启动。所以"我这能跑、你那不能跑"的差异只可能来自驱动或显卡代际。

---

## 二、API Key

默认密钥：`sk-171212e1b4a08d12xh2131234356647yu`，首次运行 `install.bat` 时会自动写入包根目录的 `api-key.txt`（纯文本、无 BOM）。本包**刻意不带** `api-key.txt` —— 这样谁拿到都不会继承别人的密钥。

- **改密钥**：直接编辑 `api-key.txt`，改完 `stop.bat` 再 `start.bat`。
- **关闭校验**：删掉 `api-key.txt`，重启后不带 key 也能访问（仅本机回环，风险不大）。
- **不要**把带密钥的包发给别人；发给别人前删掉 `api-key.txt` 即可回落成无密钥模式。
- **接了 DSH 的话**：DSH 那边另有一份密钥副本（`.credentials.yaml`），改钥匙要两边一起改，否则 401。

调用示例（PowerShell）：

```powershell
$key = Get-Content .\api-key.txt -Raw
$body = @{
  model    = 'bonsai2-27b'
  messages = @(@{ role = 'user'; content = '用一句话解释什么是三进制量化' })
  max_tokens = 1024
} | ConvertTo-Json -Depth 6

curl.exe -s http://127.0.0.1:18200/v1/chat/completions `
  -H "Content-Type: application/json" `
  -H "Authorization: Bearer $key" `
  -d $body
```

Python（openai SDK）：

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:18200/v1", api_key=open("api-key.txt").read().strip())
print(client.chat.completions.create(model="bonsai2-27b",
      messages=[{"role": "user", "content": "你好"}], max_tokens=1024).choices[0].message.content)
```

**注意**：这个模型默认"先思考再回答"。`max_tokens` 给小了（比如 128）会出现
"200 正常返回、但 content 是空的、completion_tokens 正好等于上限"——思考把额度吃完了。
给 ≥1024，或者在 prompt 里写"直接回答，不要思考过程"。

---

## 三、这份包解决的问题

原作者的开源仓库 `shensanshu/ninfer-ada-ternary`（魔搭）**是半成品**：

- 全库 89 个文件，最大 0.6 MB，总大小 1.3 MB；
- README 承诺的 `①极速档（PQ2三元）.zip`（18.4 GiB）、`00-从这里开始.md`、`自检-搬家.ps1`、`src-tree\` **全部不存在**；
- `NOTICE.md` 明写「本仓不分发模型权重」。

按指南原路复现要 CUDA 13.3 + MSVC 14.51 + CMake 4.4.3 从源码编译，还要 ≥64 GB 内存跑一次全精度转换——
16 GB 内存、没有 C++ 工具链的机器做不到。

这份包把缺的两块补齐并验证它们能对上：

| 缺的东西 | 从哪补的 | 校验 |
| --- | --- | --- |
| Windows 引擎 | KVMem `v0.18.0` 的 `kvmem-v0.18.0-ninfer-windows-rtx50-sm120a.zip` | SHA256 `F893DC90…DBDF7D` |
| 三元权重 | `WaveCut/Ternary-Bonsai-2-27B-NInfer-v3` 的 `.ninfer` | SHA256 `CDC4810B…C14A` |

**"50 系通用编码"**：官方按架构分三包——`rtx30-sm86`、`rtx40-sm89`、`rtx50-sm120a`。
`sm_120a` 是 Blackwell 全系通用指令集，包内预编译 192 个 cubin（`VALIDATION.json` 记录 SM75/86/89/120a 各 192 个）。
它不是 5070 Ti Laptop 专用，而是**整个 50 系都能跑**；本机 `compute_cap=12.0` 正好落在其中。

**兼容性验证**：三元权重是 PrismML 私有张量类型，官方 llama.cpp 加载会直接报
`tensor 'output.weight' has invalid ggml type 143`。这个引擎的二进制里 `t2_g128` 出现 2 次、`hadamard` 55 次、
`QP2_0`/`PTQ1`/`tq1_0` 全为 0 —— 只认 v3 这套格式，正好对上 WaveCut 的构件。

---

## 四、原理：27B 怎么塞进 12 GB

### 4.1 三进制权重：1.76 bit/参数

每个权重压成 `{-1, 0, +1}` 三档，再配分组缩放（FP16），有效位宽 **1.76 bit**。
27B × 1.76 bit ≈ **5.9 GB**，和 9B 的 Q4（5.56 GB）几乎一样大；代价是精度保留 **98.2%**（83.9 vs 85.4）。
GGUF 头里 851 个张量中有 **323 个是 `t2_g128_fp16`**，**517 处 hadamard** 标记。

### 4.2 Hadamard 旋转：摊平离群值

少数"特别大"的权重被压成 ±1 后损失惨重。量化前做一次 Hadamard 正交旋转把能量摊到所有通道，推理时反向旋转
（`prism.hadamard.weight_names` 记录转哪些）。这是保住 98% 精度的核心。

### 4.3 KVMem：分页 KV

KV 缓存切成 **64 token 一页**，只给真正用到的页分显存，超预算的换到 host 内存。

- `--kvmem-budget 69632`：显存里最多放 69,632 token 的 KV
- `--kvmem-gen-reserve 4096`：生成阶段余量
- `--kvmem-sink-tokens 8192`：开头 8K 常驻显存，永不换出
- `--kvmem-sessions 2`：host 里保留 2 份对话快照

**硬约束**：容量 = `budget + reserve`，与请求里的 context 无关。
实测传 `-Context 262144`，引擎照样报 `capacity | KV 49,152 tokens`。

### 4.4 MTP：投机解码

`--spec mtp --draft-tokens 2`：模型自带预测头先猜 2 个 token，主模型一次验证。
实测接受率约 41–51%，是解码能到 57–66 tok/s 的主要原因。

### 4.5 rk4v4：KV 也量化

KV 压到 4 bit 分组量化。同样 12 GB，f16 KV 只能开 32K，rk4v4 能开 72K——**这是 72K 成立的前提**。

---

## 五、门槛

| 项 | 要求 | 说明 |
| --- | --- | --- |
| 显卡 | RTX 50 系（sm_120a） | 40 系要 rtx40-sm89 包，30 系 rtx30-sm86 |
| 显存 | ≥ 12 GB | 72K + 权重实测 10.4–10.6 GB，留 1.5 GB 给桌面 |
| 内存 | ≥ 16 GB | host KV 2 GiB + 引擎约 2.2 GB；默认 12 GiB 配置在 16 GB 机器上会启动失败 |
| 磁盘 | ≥ 22 GB | 引擎 0.9 + 解压 1.7 + 权重 9.5 + 余量 |
| 驱动 | 支持 CUDA 13.x | 本机 591.91 |
| 工具链 / Python | **不需要** | 全预编译二进制 |

---

## 六、我做的优化与取舍

### 6.1 最终参数（写在 `scripts\serve.ps1`）

```powershell
-Context 73728 -HostMiB 2048 -Budget 69632 -Reserve 4096 -SinkTokens 8192 `
-KvType rk4v4 -NoVision -MtpDrafts 2 -RetainedSessions 2 -Port 18200 `
-WorkerArgs @('--no-cuda-graph','--fast-prefill-kernel','--draft-tokens','2','--prefill-chunk','512')
```

| 参数 | 为什么 |
| --- | --- |
| `-HostMiB 2048` + `-RetainedSessions 2` | 默认 12 GiB host KV 在 16 GB 机器上启动即失败；2 GiB 能跑，省约 10 GB 内存 |
| `-KvType rk4v4` | f16 KV 只能 32K；rk4v4 到 72K，解码不降速 |
| `-Context 73728 -Budget 69632 -Reserve 4096` | 满足 `budget+reserve ≤ context`，再大装不下 |
| `-SinkTokens 8192` | 长文档问答时标题/摘要常驻显存 |
| `-MtpDrafts 2` | 实测 2 最好；4/6 从 55–60 掉到 42–45 |
| `-NoVision` | 视觉塔常驻 0.73 GB，先关掉腾显存 |
| `--no-cuda-graph` | 这套构建开 CUDA Graph 启动即崩（`cudaErrorGraphExecUpdateFailure`） |
| `--prefill-chunk 512` | **防断电**，见 6.2 |

### 6.2 会瞬间断电的配置（重点）

这台机器在特定配置下**整机瞬间断电**：Kernel-Power 41、`BugcheckCode=0`、无蓝屏、无 WHEA、无过热事件。

四组对照（每次只改一个变量）：

| 实验 | 配置 | 负载 | 峰值功耗 | 结果 |
| --- | --- | --- | --- | --- |
| 1 | 9B / llama.cpp / 131072 | 3×8.9 万 token 冷预填（165 s） | 140.8 W / 88 °C | 存活 |
| 2a | ninfer + `--prefill-cublas` / chunk 512 | 62K 冷预填（101 s） | 139.8 W / 88 °C | 存活 |
| 2b | ninfer / chunk 4096 / 无 cublas | 62K 冷预填（90 s） | 140.5 W / 89 °C | 存活 |
| 2c | ninfer / chunk 4096 + cublas | 62K 冷预填 | — | **断电** |

**结论**：不是电源不够（9B 在 140.8 W 连拉 165 秒没事），而是 **宽 prefill 分块 × cuBLAS 路径**叠加时
那一次极宽的 GEMM 产生毫秒级电流尖峰——500 ms 采样看不见，但足以触发保护。
所以 `--prefill-chunk 512` 且**不开 cuBLAS**。`--device-profile calibrate` 是第二个独立断电点，同样禁用。

### 6.3 cublas 在 512 分块下没用

同样 8K 提示：chunk 512 无 cublas = 724 tok/s，chunk 512 + cublas = 709 tok/s。
cuBLAS 只在分块 ≥2048 才有收益。所以最终不开——速度一样，少一个会断电的开关。

---

## 七、与 Qwen3.5-9B 的全面对比

两者都是本机部署、都在 12 GB 显存下。9B 用 llama.cpp + Q4_K_M（131072 上下文）。

### 7.1 规格

| 项 | Bonsai 27B | Qwen3.5-9B |
| --- | --- | --- |
| 参数量 | 27B（三进制） | 8.95B（Q4_K_M） |
| 权重体积 | 9.52 GB（.ninfer） | 5.56 GB（.gguf） |
| 显存 | 10.4–10.6 GB @72K | 10.27 GB @131072 |
| 上下文 | 73,728（页池限制） | 131,072（显存限制） |
| 多模态 | 有视觉塔（本包关闭） | 原生多模态（无 mmproj，当前纯文本） |
| 引擎 | KVMem / NInfer | llama.cpp b11669 |
| 换硬件 | 必须 sm_120a 同代 | 任意 CUDA |

### 7.2 速度（同机、62–71K 提示）

| 指标 | Bonsai 27B | Qwen3.5-9B |
| --- | --- | --- |
| 预填充（20K） | 679 tok/s | 2,813 tok/s（8K 时） |
| 预填充（48K） | 604 tok/s | — |
| 预填充（71K） | 564 tok/s | — |
| 首字延迟（20K） | 29.5 s | 约 7 s |
| 首字延迟（71K） | 124.7 s | 约 25 s |
| 解码 | 57–66 tok/s | 55.5 tok/s |
| 解码（长文） | 58.9 tok/s | 40.4 tok/s |

**读法**：9B 预填充快 4–5 倍（稠密小模型 + 常规注意力），但解码持平，长上下文 Bonsai 反而更快。

### 7.3 智慧（同一套 8 题）

| 题目 | Bonsai 27B | Qwen3.5-9B |
| --- | --- | --- |
| 三管注水（36/7≈5.14h） | ✅ 正确 | ❌ 算成 9 小时 |
| 写 `longest_inc` 代码 | ✅ | ✅ |
| 严格格式三行输出 | ✅ | ✅ |
| 虚构条约辨认 | ❌ 编造「1589 年」 | ❌ 编造「1815 年」 |
| 长材料抽细节 | ✅ | ✅ |
| 严格 JSON | ✅ | ✅ |
| 三人真假话推理 | ✅ | ✅ |
| 找二分查找 bug | ✅ | ✅ |

**结论**：Bonsai 在**算术/多步计算**上明显更强；事实性幻觉两者一样，不会因为 27B 就消失。

### 7.4 什么时候用哪个

| 场景 | 推荐 |
| --- | --- |
| 长文档一次读完 | **Bonsai 72K** |
| 日常问答、写代码 | **9B**（首字快 4 倍） |
| 多步计算、数字推理 | **Bonsai** |
| 接 DSH 当 agent | **9B**（预填充快、工具调用稳） |

---

## 八、接进 DeepSeek Harness

分两件事：**① 让模型出现在 DSH 的模型列表里**（改配置，手动做一次）；**② 装左下角开关插件**（双击 install.bat，以后用开关启停）。

### 8.1 先确认服务在跑

双击 `status.bat`，看到「状态 : 运行中」和 `http://127.0.0.1:18200/v1` 才行。没跑就先 `start.bat`。

### 8.2 在 DSH 里添加这个模型

DSH → 左下齿轮 **设置** → **模型** → **添加模型提供商** → 选 **自定义模型 API**，按下表填：

| 字段 | 填什么 |
| --- | --- |
| Provider ID | `local-bonsai` |
| 显示名 | `Bonsai-27B-72K` |
| 端点 | `http://127.0.0.1:18200/v1` |
| 协议 | `OpenAI Chat Completions` |
| API 密钥 | `api-key.txt` 里那一串（默认 `sk-1712…`） |
| 模型 | 点「获取可用模型」→ 勾 `bonsai2-27b`（也可手填 id） |
| 上下文窗口 | `73728` |
| 最大输出 token | `8192` |

保存后**完全退出 DSH 再打开**（托盘也要退）。只关窗口不算——提供商和凭据只在启动时读一次。

> **如果保存时报 `profile reload requires the root Include entry`**：这是当前进程的热重载缺陷，不是你填错了。改成手写配置文件，见 8.3。

### 8.3 手动改配置（UI 报错时的替代方案）

先退出 DSH，然后编辑这两个文件（都在 `C:\Users\<你>\.dsh\` 下）：

`profiles\desktop\cordis.patch.yml` —— 在 `llm-pi-ai` 的 `providers:` 下面加一段（注意缩进是空格，不能用 Tab）：

```yaml
        local-bonsai:
          displayName: Bonsai-27B-72K
          api: openai-completions
          baseURL: http://127.0.0.1:18200/v1
          apiKeyEnv: LOCAL_BONSAI_API_KEY
          models:
            - id: bonsai2-27b
              name: Bonsai 27B (KVMem 72K)
              contextWindow: 73728
              maxTokens: 8192
```

`.credentials.yaml` —— 在文件末尾的 `refs:` 下面加一行（缩进 2 空格，值与 `api-key.txt` 完全一致，不要加引号）：

```yaml
  LOCAL_BONSAI_API_KEY: sk-171212e1b4a08d12xh2131234356647yu
```

保存后重新打开 DSH。两点必须对齐：`apiKeyEnv` 写的名字 = `refs` 里的键名。

### 8.4 装左下角开关插件

插件包：`dsh-local-model-toggle-plugin-0.6.0.zip`（就在这个文件夹里）。

1. **解压**到一个固定位置（别放临时目录），比如 `D:\dsh-local-model-toggle`。
2. **双击里面的 `install.bat`**；如果你想让它直接认这个部署夹，把**文件夹拖到 install.bat 上**，或命令行 `install.bat "D:\...\Bonsai-27B-72K"`。
3. 脚本会：复制插件到 `%USERPROFILE%\.dsh\plugins\`、在 profile 的 `node_modules` 建 Junction、往 `package.json` 的 dependencies 与 bundles 里登记、写一份 `config.json`（记住部署夹）。
4. **完全退出 DSH 再打开**。左下角（设置齿轮上方）会出现一个蓝色胶囊开关，写着当前模型名。

装完后的用法：

| 操作 | 效果 |
| --- | --- |
| 左键点开关 | 启动 / 停止当前选中的模型（停止只杀这个端口，不会误伤另一个） |
| 右键点开关 | 弹出面板：切换模型、看/改部署夹、设「闲置自动关闭」分钟数、看最近日志 |
| 红点 + 「选择部署夹」 | 它找不到 `scripts\serve.ps1`，右键选一次正确目录即可 |

### 8.5 验证清单

| 检查 | 期望 |
| --- | --- |
| `status.bat` | 运行中，18200，模型 `bonsai2-27b`，上下文 73728 |
| DSH 设置 → 模型 | 列表里有 `Bonsai-27B-72K` |
| DSH 左下角开关 | 蓝色胶囊，绿点，写着 `Bonsai-27B-72K` |
| 开关右键菜单 | 能看到 `bonsai2-27b`（端口 18200）并处于选中态 |
| 发一句话 | 正常回；`max_tokens` 给 ≥1024 |

---

## 九、已知问题

1. **思考模式吃 token**：`max_tokens` 小于 1024 常常只有思考没有正文。
2. **`reasoning_effort: "high"` 会 HTTP 500**，用 `xhigh`/`medium` 或不传。
3. **解码到 62K 后短样本测速会失真**：9 token 样本测出 15 tok/s 是伪影；400 token 样本是 58–66 tok/s。
4. **视觉不可用**：本包 `-NoVision`。要用去掉它，并把 `--kvmem-budget` 降到 65536 左右腾 0.73 GB。
5. **重启电脑后要重开**：没做开机自启（避免常驻占显存）。
6. **换显卡必须换引擎包**：sm_120a 的 cubin 在 40 系上跑不了。
7. **`start.bat` 在管道里调用会挂住**：它用 `Start-Process` 拉后台进程，子进程继承了控制台句柄。双击运行没这个问题。
8. **DSH 里改设置可能报 root Include 错**：见 8.3，手写 YAML 绕过。

---

## 十、目录与校验

```
Bonsai-27B-72K\
├─ install.bat            首次：一键部署（下载 + 校验 + 解压 + 启动）
├─ start.bat              启动
├─ stop.bat               停止（只杀自己这个端口的进程）
├─ status.bat             状态
├─ 重置下载.bat           下载卡死时清 download\ 重来
├─ api-key.txt            API 密钥（install 首次运行时自动生成）
├─ README.md              本文
├─ 使用说明.html          同一份内容的网页版
├─ dsh-local-model-toggle-plugin-0.6.0.zip   DSH 左下角开关插件
├─ scripts\
│   ├─ install.ps1        部署逻辑
│   └─ serve.ps1          启动/停止/状态逻辑
├─ engine\                install 后出现：引擎（约 1.0 GB）
├─ model\                 install 后出现：权重（9.5 GB）
├─ download\              install 后出现：下载缓存（可删）
└─ run\                   运行时：host.pid / config.json / 日志
```

`engine\` `model\` `download\` `run\` 都由脚本按需创建，**不需要事先手工建**。

| 文件 | SHA256 |
| --- | --- |
| 引擎 zip | `F893DC9053CB27EF8CDBC32687C6BB29346D5829D5EB2272A58DDEF7B6DBDF7D` |
| 权重 .ninfer | `CDC4810B0FF17C40D0F62CF214B6E0BCD08346E9EB05CA53371507037793C14A` |

---

## 十一、这个包验证到什么程度

我在这台机器上做了这些验证（都是实测，不是推断）：

| 验证项 | 结果 |
| --- | --- |
| 干净目录 `install.bat -DryRun` | ✅ 正确列出环境检查与下载计划，不落盘 |
| 干净目录真实部署（本地文件注入） | ✅ 引擎解压、权重 SHA 校验、api-key 写入，8 秒完成 |
| 从干净目录 `start.bat` 启动 | ✅ 约 10 秒 `/health` 200，显存 10.4 GB |
| 无 key 访问 `/v1/models` | ✅ 401 |
| 正确 key 访问 | ✅ 200 |
| 错误 key 访问 | ✅ 401 |
| 真实对话请求 | ✅ 200，decode 51.7 tok/s |
| `stop.bat` | ✅ 杀掉本端口进程，显存回落 1.3 GB |
| 下载地址可达性 | ✅ 两个 URL 都 200，`content-length` 与期望字节数一致 |
| 接入 DSH 后对话 | ✅ 回「接入成功」 |

**没验证到的**：真机重装系统后从公网完整下载 10.4 GB 的端到端过程（下载太慢）。
不过下载走的是 `curl -C -` 断点续传 + SHA256 硬校验，任何中断重跑都能续上。

---

## 十二、下载这条链路是怎么处理的

首次部署要下 10.4 GB，这段以前最容易出问题，现在做了几件事：

| 机制 | 行为 |
| --- | --- |
| **多源兜底** | 先测 8 个 GitHub 镜像的速度，按快慢排序依次尝试；一个源失败或卡住就自动换下一个 |
| **直连放最后** | 直连常常「开头很快、几 MB 后就断流」，所以即使测速第一也不当首选 |
| **卡死检测** | 45 秒文件没有任何增长，就杀掉 curl、保留已下载部分、换源续传 |
| **进度条** | 每 0.8 秒刷新：百分比、已下/总量、实时速度、剩余时间；输出被重定向时退化成每 10% 一行 |
| **TLS 兼容** | 自动带 `--ssl-no-revoke`，避免某些网络下 `curl: (35) CRYPT_E_NO_REVOCATION_CHECK` 直接失败 |

知道某个镜像特别快，也可以手动指定：

```
install.bat -Proxy https://gh-proxy.com/
```

权重默认从 `hf-mirror.com` 下，失败会自动退到 `huggingface.co`。

---

## 十三、版本变更

| 版本 | 变化 |
| --- | --- |
| v1.3 | 新增完整 DSH 接入章节（模型提供商 + 开关插件 + 验证清单）；补「安装后目录」；包内附带插件 zip |
| v1.2 | 下载加进度条、8 源自动测速与失败换源、45 秒卡死检测、`--ssl-no-revoke` 修复 TLS 报错、权重双源兜底 |
| v1.1 | 新增 `install.bat` 一键部署（含环境自检、SHA256 校验、VC++ 自动安装）、`api-key.txt` 默认密钥 |
| v1.0 | 首个可复现包：`start/stop/status` 三个 bat + `serve.ps1` |

---

## 十四、来源链接

- 权重（本包用的 v3 构件）：<https://hf-mirror.com/WaveCut/Ternary-Bonsai-2-27B-NInfer-v3>
- 权重（GGUF 原始仓）：<https://hf-mirror.com/prism-ml/Ternary-Bonsai-2-27B-gguf>
- 引擎：<https://github.com/kvmem/kvmem/releases/tag/v0.18.0>
- 原作者指南（缺件的那份）：<https://modelscope.cn/models/shensanshu/ninfer-ada-ternary>
- 同型号硬件参考工程：<https://github.com/CSUNX233/qwen3.8-27b-ninfer-5070tilaptop-kvmem-local-agent>

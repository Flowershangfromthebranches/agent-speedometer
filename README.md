# AgentPulse · Agent 速度表

**给 Claude Code 和 Codex 加上实时的 tok/s 速度表。** 这是一个 macOS 菜单栏小工具，能实时显示 agent 当前对话的模型输出速度、TTFT、token 用量、缓存命中率和上下文占用，同时开着多个 agent 也能逐个切换查看。

样式参考 DeepSeek harness 底部的状态栏。它只读取本机日志：不联网，不碰账号，不改任何配置。

[![下载最新版](https://img.shields.io/github/v/release/Flowershangfromthebranches/agent-speedometer?label=下载&color=2ea44f)](https://github.com/Flowershangfromthebranches/agent-speedometer/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

![悬浮条与会话统计](docs/screenshots/hud.png)

| 菜单栏详情页 | 切换会话 |
|---|---|
| ![速度详情](docs/screenshots/popover-speed.png) | ![会话列表](docs/screenshots/popover-session.png) |
| ![Token 用量](docs/screenshots/popover-tokens.png) | ![上下文占用](docs/screenshots/popover-context.png) |

<details>
<summary>设置窗口</summary>

<img src="docs/screenshots/settings.png" width="460" alt="设置窗口">

</details>

> 截图中的会话和数据都是演示数据，由 `AgentPulse --render <目录> --demo` 生成。

数据有两种看法，设置在单独的窗口里：

- **悬浮条**：始终置顶，不会抢走焦点。点击某一段就在旁边弹出详情卡。
- **顶部菜单栏模块**：每个模块单独作为一个菜单栏项，想放哪些自己选。点击打开详情页，详情页里可以直接切换会话，也能用 ⚙︎ 打开设置。
- **设置窗口**：独立的窗口，不挂在菜单栏上。打开方式：任意详情页右上角的 ⚙︎、悬浮条右键 →“打开设置…”，或者在 Finder / 启动台里再次打开 AgentPulse。

## 支持的工具

| 工具 | 日志位置 | 说明 |
|---|---|---|
| Claude Code 命令行版 / Claude 桌面版的 Code 标签页 | `~/.claude/projects/*/*.jsonl` | 日志不记录首 token 时间，速度里包含首 token 的等待，数值略偏低 |
| Codex 命令行版 / Codex 桌面版 | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | 有首个输出的时间，可以显示真实的 TTFT |

不支持：Claude 桌面版的普通聊天（Code 标签页之外的对话），以及不在本地写日志的 agent 工具。原因见下文“合规与安全”。

## 安装

1. 到 [Releases](https://github.com/Flowershangfromthebranches/agent-speedometer/releases/latest) 下载 `AgentPulse-<版本>.dmg`。
2. 打开 dmg，把 AgentPulse 拖进“应用程序”。
3. 第一次打开时，在“应用程序”里**右键 AgentPulse → 打开**，再点一次“打开”。

第 3 步是因为应用只做了 ad-hoc 签名，没有 Apple 开发者证书公证，直接双击会被 macOS 拦下。如果右键打开也不行，可以到“系统设置 → 隐私与安全性”里点“仍要打开”。

不放心预编译版本的话，也可以按下文“从源码构建”自己编译。

## 使用

### 悬浮条

| 位置 | 操作 |
|---|---|
| 左侧模型名 | **点击**：弹出会话列表并切换会话<br>**拖动**：移动悬浮条位置（位置会被记住） |
| 速度段 / Token 段 / 上下文段 | 点击打开详情卡，再点一次或点外面关闭 |
| 任意位置右键 | 打开设置 / 隐藏悬浮条 |

悬浮条的尺寸是固定的，鼠标靠近、移动都不会让它变化。

### 切换会话

后台会同时解析最近活跃的 8 个会话，每个会话的速度都在实时更新。

- 会话列表里每一行显示：项目名、工具、模型、实时 tok/s 和上下文占用。正在生成的会话前面有绿点，后面显示已经生成了多久。
- 点某一行就固定查看它，模型名后面会出现 📌。
- 点“自动跟随最新会话”回到自动模式，这时显示最近有写入的那个会话。
- 会话列表在三个地方都有：悬浮条左侧的模型名、任意菜单栏模块详情页顶部的会话名（点一下展开）、设置窗口。

### 顶部菜单栏模块

在设置窗口的“顶部菜单栏模块”里，可以单独开关这四个模块：

| 模块 | 菜单栏显示 | 点击后 |
|---|---|---|
| 会话 / 模型名 | `✦ claude-opus-5-5 📌` | 会话列表，可以切换 |
| 速度 | `110 tok/s`（只有文字，不带图标） | 会话统计：模型用时、工具用时、TTFT、各种速度 |
| Token 用量 | `▤ 4.3M · 97.3%` | Token 明细：未缓存输入、缓存读写、输出；Codex 还会显示额度窗口 |
| 上下文占用 | `◔ 78%` | 上下文进度条、模型和窗口大小 |

默认只开“速度”。模块至少要保留一个，因为详情页和设置要从模块进入。按住 ⌘ 拖动可以调整这些模块在菜单栏里的顺序。

每个模块的详情页顶部是“当前会话名 ⌄”，点一下就能展开会话列表直接切换；右上角的 ⚙︎ 用来打开设置窗口。

> 带刘海的 MacBook 上，如果菜单栏图标太多，macOS 会把放不下的图标藏到刘海后面。开了模块却看不到时，可以退出几个不常用的菜单栏应用，或者按住 ⌘ 把模块拖到靠右的位置。

## 指标说明

- **轮**：你发出的消息数。**步**：模型请求次数（每次工具调用后模型会再被调用一次）。
- **输出速度** = 输出 token ÷ 生成耗时。如果日志记录了首个输出的时间（Codex），就扣掉首 token 之前的等待。少于 20 个 token 或短于 0.25 秒的步骤不计入，避免噪声。
  - 悬浮条和菜单栏显示的是“近 5 步”的速度。详情里另外还有“最近一步”和“会话平均”。
- **工具调用用时**：从一步结束，到触发下一步的工具结果返回之间的时间。
- **上下文**：最近一次请求的输入 token ÷ 模型的上下文窗口。
  - Codex 的窗口大小来自日志。Claude Code 的日志里没有窗口大小，默认自动估计，也可以在设置里手动选 200K 或 1M。
- **生成中**：最新事件是用户消息或工具结果、还没等到回复时显示。任务完成、被中断、API 报错都会结束这个状态。

**局限**：日志要等每个内容块写完才会落盘，所以速度是**每一步更新一次**，没法随着打字逐 token 刷新。想要流式级别的速度，就得去截获网络流量，这个项目刻意不这么做，原因见下文。

## 合规与安全

设计原则：**完全不碰 agent 工具本身和它们的服务**，只读取这些工具自己已经写在你本机上的日志。

会做的事：

- **只读**方式读取 `~/.claude/projects` 和 `~/.codex/sessions`。
- 只取时间戳、token 用量、模型名、工作目录、上下文窗口这些元数据。
- 消息正文、工具输入和输出一律不保存、不显示、不上传。这些日志里有你完整的对话，包括你粘贴进去的密钥。

不会做的事（源码里没有 `URLSession`、网络、钥匙串或写文件相关的调用）：

- 不联网，不调用任何 API，包括未公开的用量和额度接口。
- 不读 `~/.codex/auth.json`、钥匙串或 OAuth token，也从不以你的身份认证。
- 不搭本地代理、不做中间人截获，不改 agent 工具的 `base_url` 等任何配置。
- 不向 Electron 或桌面应用注入代码、不修改它们，也不借助辅助功能或屏幕录制去读界面。
- 不向模型发请求，所以不消耗你的额度。
- 不需要辅助功能、屏幕录制等任何系统权限。

所以 AgentPulse 只是一个被动的本地日志查看器，对这些服务来说它根本不存在。

注意：以上是工程层面的判断，不构成法律意见。将来某个工具改了日志格式或位置，只需要更新解析器，不会转而采用上面列出的任何方式。

## 从源码构建

需要 macOS 13 以上，以及 Xcode（或 SwiftPM 能正常用的 Command Line Tools）。

```bash
scripts/build-app.sh            # 生成 dist/AgentPulse.app 和 dist/AgentPulse-<版本>.dmg
scripts/build-app.sh --install  # 另外安装到 /Applications
```

调试命令（不启动界面）：

```bash
.build/release/AgentPulse --dump                 # 输出最近会话的统计
.build/release/AgentPulse --dump <session.jsonl> # 指定某个日志文件
.build/release/AgentPulse --render ./preview          # 用你的真实会话把界面渲染成 PNG
.build/release/AgentPulse --render ./preview --demo   # 用演示数据渲染（README 截图就是这样生成的）
```

### 代码结构

| 文件 | 作用 |
|---|---|
| `Sources/AgentPulse/Parsers.swift` | Claude Code / Codex 日志解析，增量读取文件尾部 |
| `Sources/AgentPulse/Model.swift` | 每一步的记录和各项统计的计算 |
| `Sources/AgentPulse/Monitor.swift` | 会话发现，多会话同时跟踪 |
| `Sources/AgentPulse/HUD.swift` | 悬浮条和详情卡窗口 |
| `Sources/AgentPulse/MenuBarModules.swift` | 顶部菜单栏的各个独立模块 |
| `Sources/AgentPulse/Views.swift` | 状态条、详情卡、会话列表等界面 |
| `Sources/AgentPulse/App.swift` | 应用入口和独立的设置窗口 |
| `scripts/build-app.sh` / `scripts/make-icon.swift` | 打包脚本和图标生成 |

### 接入新工具

参照 `Parsers.swift` 给新工具的本地日志格式写一个 `SessionParser`，再在 `SessionDiscovery` 里加上它的日志目录。前提是这个工具自己会把日志写在本地。

## 许可证

[Apache License 2.0](LICENSE)

本项目与 Anthropic、OpenAI、DeepSeek 没有关联。Claude、Codex 等名称归各自所有者所有，这里只用来说明本工具兼容哪些软件。

## 更新记录

### 0.5.0
- 开源发布到 GitHub，采用 Apache-2.0 许可证。README 加入用演示数据生成的截图。
- 修复悬浮条在空间不够时“3 轮 223 步”被截断的问题。
- 去掉菜单栏里单独的设置图标，节省菜单栏空间。
- 速度模块只显示文字“xxx tok/s”，不再带图标。
- 每个模块的详情页新增：顶部的会话名可以点开直接切换会话，右上角 ⚙︎ 打开设置。
- 设置改成独立窗口，不再挂在菜单栏下面。悬浮条右键菜单、再次打开 App 也能进入设置。
- 菜单栏模块至少保留一个，避免详情和设置都没有入口。

### 0.4.0
- 新增顶部菜单栏模块：会话/模型名、速度、Token 用量、上下文四个模块各自独立，可以分别开关，点击出现详情弹窗。
- 主菜单栏图标改为只显示图标，面板里换成精简概要，会话列表最多显示 5 行。
- 打包成带图标的 `.app` 和 `.dmg`。
- README 改为中文。

### 0.3.0
- 点击悬浮条左侧的模型名可以选择查看哪个会话，列表里显示每个会话的实时速度、上下文占用和生成状态。
- 后台同时跟踪最近 8 个会话，切换是即时的。
- 修复被中断的会话仍然显示“生成中”的问题：会识别 Codex 的任务完成和中断，以及 Claude 的用户中断和 API 报错。

### 0.2.0
- 修复鼠标靠近悬浮条时不停抖动的问题。原因是悬停时弹出详情卡、窗口跟着变大，又让鼠标“离开”，形成循环。
  - 现在悬停不再触发任何变化，详情卡改成点击后在独立的小窗口里打开。
  - 速度和计时区域的宽度固定，悬浮条尺寸不再随计时变化。

### 0.1.0
- 第一版：菜单栏速度显示，以及仿 DeepSeek 样式的悬浮条（轮/步/速度、Token/缓存命中、上下文占用和三张详情卡）。
- 支持 Claude Code（含 Claude 桌面版的 Code 标签页）和 Codex（命令行版和桌面版）的本地日志。
- 用真实会话验证过解析：18MB 的日志 0.18 秒解析完成。

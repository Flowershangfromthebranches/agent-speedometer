# AgentPulse · Windows 版

**专为 Windows 开发者打造的 AI Agent 实时 tok/s 速度表。**

自动扫描本机安装的 Coding Agent 工具（桌面端与 CLI），实时呈现当前对话的模型输出速度、TTFT（首字耗时）、Token 用量、缓存命中率以及上下文占比。同时支持多会话切换、历史会话分组浏览、每步速度走势（悬停查看详情）以及近 7/30/90 天 Token 消耗与费用汇总。

> **纯本地只读原则**：不联网、不碰账号、不改任何配置文件，只以只读方式读取本机 agent 工具生成的本地日志。

## 运行方式

### 推荐：安装包
- 到 [Releases](https://github.com/Flowershangfromthebranches/agent-speedometer/releases/latest) 下载 `AgentPulse-Setup-<版本>.exe`，双击安装即可，无需 Python 环境。
- 安装包由 GitHub Actions 在 Windows 上自动构建（见 `.github/workflows/windows-release.yml` 与 `installer/AgentPulse.iss`）。

### 方式一：双击直接运行（免安装）
- 双击运行 **run.bat** 或 **agentpulse.pyw**

### 方式二：命令行运行
- 启动桌面悬浮条与看板：`python agentpulse.py`
- 列出检测到的 agent 工具与会话数：`python agentpulse.py --tools`
- 终端实时 tok/s 速度表：`python agentpulse.py --watch`
- 输出最近 30 天 token 用量与费用估算：`python agentpulse.py --usage 30`
- 查看指定工具最近 3 个会话统计：`python agentpulse.py --dump-tool codex 3`

### 方式三：自行打包为独立 Windows 可执行程序
- 运行 **build.bat** 即可生成不需要 Python 环境的 `dist/AgentPulse/AgentPulse.exe`。

# Qoder Credits 计量口径

核对日期：2026-10-22。仅被动读取现有本地日志，不发起模型请求或认证，不读取账号凭据。

## 字段来源

官方依据：[Qoder CN SDK 成本和用量](https://docs.qoder.cn/cli/sdk/cost-usage)。

- Assistant 消息 `message.usage.credits`：优惠后的单次请求 Credits。
- `original_credits`：优惠前的单次请求参考值，不能作为额外消耗相加。
- `billable`：是否计入用户的 Credits 用量。
- Result 的 `total_credits`：会话累计值，不能与请求值相加，也不能累加多个 Result。
- 字段可选；缺失不代表消耗为零。

目前读取 JSONL Assistant 请求记录，不读取 Result 累计值。请求 id 优先使用 `usage.request_id`，其次为 `message.id`，再其次为日志 `uuid`。同一请求的多个内容块，以及恢复或分叉会话中复制的请求，只计一次。国际版和 CN 版分别去重、分别展示。

## 实际用量与速度公式

```text
billable == false                         → 实际计费 Credits = 0
billable == true 且 credits 是有效非负数    → 实际计费 Credits = credits
其他情况                                  → 未知，不用 0 替代

单次 Credits/s = 本次实际计费 Credits / 本次请求耗时
区间平均 Credits/s = Σ实际计费 Credits / Σ对应请求耗时
```

请求起点取前一条用户消息或工具结果的时间戳，终点取带 usage 的 Assistant 记录时间戳。每次工具结果会重置起点，因此可识别的工具执行间隔不计入请求耗时。这个时长含等待，不是首 token 至末 token 的纯解码时长。缺少起点或时长不足 0.25 秒时，只统计用量，不计算速度。最近值取最近 5 次具备完整计费和时间数据的请求，图中保留最近 40 次，步号保留原会话序号。

如果请求未计费，其实际消耗速度为 0，即使服务器报告了非零的参考 Credits。这不能用来断言该请求没有生成 token。日统计以请求完成时间归档；旧日志缺字段时页面显示覆盖次数和缺失次数。

## Token 换算规则状态

**当前没有启用任何 Credits → token 系数。**

官方文档明确说明 token 字段与 Credits 没有固定换算关系；[模型档位系数](https://docs.qoder.com/cli/model)用于比较消费档位，不是每 Credit 对应的 token 数，也不能再乘到已经结算的 `credits` 上。[国际版和 CN 版 Credits 也不等价](https://docs.qoder.cn/product-overview/account-subscription-faq)。

后续若加入换算，需要保留规则来源、软件版本、模型、计费类型、缓存和优惠条件、生效日期，并用同时具备 token 与 Credits 的同一批请求核对误差。只有 Credits 的历史日志无法独立验证换算系数，也无法唯一拆分输入、输出与缓存 token。社区单一样本的经验比例不足以视为准确公式。

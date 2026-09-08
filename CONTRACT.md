# PiAgentCore 合同

两端共用。桌面端是 pi 0.85.1 本尊，iOS 是本仓库的 Swift 移植。本文只写"必须一样"的部分。

## 1. 消息

- 三种模型消息：user / assistant / toolResult；App 自定义消息是 custom，convertToLlm 决定它给模型看成什么（默认丢掉）。
- 内容块：text、thinking（带签名）、toolCall（id、name、arguments）、image。
- assistant.stopReason：pending / stop / length / toolUse / error / aborted / deferred。error 与 aborted 带 errorMessage。
- timestamp 是毫秒整数。
- `prompt(字符串)` 一律产出块数组 `[{type:"text",text}]`，即使没有附图；不要退化成纯字符串。

## 2. 事件（10 种，顺序见规划文档图 2）

agent_start · turn_start · message_start · message_update · message_end · tool_execution_start · tool_execution_update · tool_execution_end · turn_end · agent_end

- message_update 只出现在助手消息流式期间，每条附整条消息快照。
- 工具结果消息也走 message_start / message_end。
- agent_end 携带本次运行新增的全部消息。

## 3. 钩子

| 钩子 | 时机 | 能做什么 |
|---|---|---|
| transformContext | 每次模型请求前 | 改写 AgentMessage 列表（压缩、注入） |
| convertToLlm | transformContext 之后 | 变成模型能懂的三种消息 |
| getApiKey | 每次模型请求前 | 提供短期凭据 |
| beforeToolCall | 参数校验后、执行前 | block（可带 reason、terminate） |
| afterToolCall | 执行后、tool_execution_end 前 | 覆盖 content / details / isError / usage / terminate |
| shouldStopAfterTurn | turn_end 后 | true 则发 agent_end 收工，不再看队列 |
| getSteeringMessages | turn_end 后、prepareNextTurn 后 | 提供插话 |
| getFollowUpMessages | 循环准备收工时 | 提供追问 |
| prepareNextTurn | 确定要再跑一轮时、turn_start 前 | 换上下文 / 模型 / 思考等级 |

## 4. 顺序规则（金标准锁住）

1. 监听器按订阅顺序依次 await，一条事件发完再发下一条；agent_end 的监听器跑完 Agent 才空闲。
2. 并行模式：tool_execution_end 按完成顺序；工具结果消息按助手源顺序。顺序模式两者都按源顺序。一批里只要有 sequential 工具，整批顺序执行。
3. stopReason 为 length 的消息，所有工具调用标失败、不执行，然后照常再跑一轮。
4. 整批结果都 terminate 才提前收工；被 block 的调用也可带 terminate。
5. prepareNextTurn 只在确定要再跑一轮时调用；调用后若此前插话队列为空，再查一次。
6. 流函数不抛错：网络、鉴权、模型错误编码成 error 事件与 stopReason 为 error / aborted 的消息。
7. 工具参数先纠偏再校验，顺序是：删可选字段的 null → 按 schema 纠偏 → 校验，第一条错误抛出。

## 5. 取消

- 取消是 Task 取消（pi 是 AbortSignal），循环在相同检查点看：工具准备后、并行任务启动前、顺序执行每个工具后。
- 取消时流函数收到 stream.cancel()，应以 aborted 的 error 事件收尾。
- 循环另有一道保险：一旦当前 Task 被取消，就不再消费流里已经排队的增量，也不等 result()，直接把这一轮的助手消息记为 `aborted` + `errorMessage: "Request was aborted"`。pi 靠 JS 微任务让供应商与消费方逐条交替，所以供应商总能在下一个检查点看到 signal；Swift 的 AsyncStream 是无界缓冲，供应商可能已经跑完，靠它自己收尾不可靠。
- 取消瞬间供应商已经排队的增量条数取决于调度，不属于合同（金标准比对时丢弃 abort 之后的 message_update，aborted 消息的 content 一律记为 `"<aborted>"`）。
- 进行中的工具能不能真的停，由执行环境决定，不属于合同（iOS 的 iSH 规则见规划文档 7.2）。

## 6. 与 pi 的已知差异

| 项目 | pi | PiAgentCore |
|---|---|---|
| 钩子拿到的 context | 可变对象 | 值快照；prepareNextTurn 返回替换用的 context |
| 自定义消息 | TS 声明合并 | custom 分支 + JSON 载荷 |
| 流函数 signal | AbortSignal 参数 | stream.cancel() 回调 |
| 流没有终止事件就结束 | result() 永不 resolve | result() 为空，循环合成 error 消息 |
| 取消后的收尾 | 等供应商推 aborted 终止事件 | 循环直接判定 aborted，不等供应商（见第 5 节） |
| prompt() 运行中再调 | 抛 Error | 抛 AgentError.alreadyProcessing |
| 参数校验 | typebox 编译校验 | 自写子集（type/required/properties/additionalProperties/items/enum/const/anyOf/oneOf/allOf） |
| AssistantMessage 字段 | 含 diagnostics、deferred | 未移植这两个字段（解码时忽略，重新编码会丢） |

## 7. 对齐方式

UPSTREAM.md 记录对齐版本；docs/upstream-map.md 记录文件映射；Tests/PiAgentCoreTests/Fixtures 里的金标准由桌面端 `npm run trace:export` 导出，归一化规则见 TraceNormalizer.swift 与 trace-export.ts 头部注释。

# Filebeat Processor 容量评估工具设计

> 最终推荐方案：业务提供两份原生 Filebeat processor 配置，一份完整生产版，一份同语法删减版。工具用删减版配置和样例日志生成实时日志，用完整生产版配置启动真实 Filebeat 做容量测试。
>
> 本机 Beats 源码实际位置：`D:\beats-main\beats-main`。

---

## 1. 结论

本工具要解决的问题是：业务在部署 Filebeat 前，想知道某套 processor 配置在指定日志 TPS 下需要多少 CPU、内存、磁盘和网络资源。

最终方案不做“万能日志反推器”，也不要求业务学习新的日志生成 DSL。业务只需要提供：

```text
processors.full.yml       # 完整生产 processors，容量测试时真实 Filebeat 原样执行
processors.generate.yml   # 从 full 删除复杂/不稳定/无关 processor 后得到，仍是 Filebeat 原生语法
samples.log               # 代表性原始日志样例，建议 20 到 100 行
dimensions.yml            # 可选，业务已有汇聚维度、权重和基数
run 参数                  # qps、duration、warmup、start-time、time-step 等
```

工具只在输入可验证时运行；无法验证就失败，不输出不可信报告。

---

## 2. 设计原则

1. **真实执行**：容量测试必须启动真实 Filebeat，并执行完整 `processors.full.yml`。
2. **同语法删减**：业务删减 processor，不写新语法。
3. **不猜复杂逻辑**：`script`、`drop_event`、`dns`、metadata 等不作为日志生成依据。
4. **强校验**：生成样本必须 100% 通过预校验，否则不进入压测。
5. **进程自身口径**：CPU、内存、磁盘 IO 默认只统计 Filebeat 进程自身。
6. **可复现**：同样输入、seed、QPS 下生成结果和报告应可复现。
7. **失败优先**：宁可失败，也不隐式降级生成不可信日志。

---

## 3. 总体流程

```text
processors.full.yml
processors.generate.yml
samples.log
可选 dimensions.yml
run 参数
        ↓
输入校验
        ↓
从 processors.generate.yml 编译日志生成计划
        ↓
从 samples.log 和 dimensions.yml 提取候选值、权重、基数、字段类型
        ↓
生成少量样本并启动真实 Filebeat 预校验
        ↓
按 QPS 实时写日志文件
        ↓
真实 Filebeat harvest 文件并执行 processors.full.yml
        ↓
采集 Filebeat 进程 CPU / 内存 / 磁盘 IO / 可选网络 / Filebeat stats
        ↓
输出容量报告
```

---

## 4. 业务输入

### 4.1 processors.full.yml

完整生产 processor 配置。压测时原样注入 Filebeat。

```yaml
processors:
  - dissect:
      tokenizer: "%{ts} %{level} app=%{app} trace=%{trace_id} ip=%{client_ip} method=%{method} path=%{path} status=%{status} latency=%{latency_ms} payload=%{payload}"
      field: message
      target_prefix: ""
      overwrite_keys: true
  - decode_json_fields:
      fields: ["payload"]
      target: "payload"
      overwrite_keys: true
  - timestamp:
      field: ts
      layouts:
        - "2006-01-02T15:04:05.000Z07:00"
      target_field: "@timestamp"
  - convert:
      fields:
        - {from: "status", type: "integer"}
        - {from: "latency_ms", type: "integer"}
      fail_on_error: true
  - drop_event:
      when:
        equals:
          path: "/health"
```

### 4.2 processors.generate.yml

同语法删减版，只保留能描述原始日志格式的 processor。

```yaml
processors:
  - dissect:
      tokenizer: "%{ts} %{level} app=%{app} trace=%{trace_id} ip=%{client_ip} method=%{method} path=%{path} status=%{status} latency=%{latency_ms} payload=%{payload}"
      field: message
      target_prefix: ""
      overwrite_keys: true
  - decode_json_fields:
      fields: ["payload"]
      target: "payload"
      overwrite_keys: true
  - timestamp:
      field: ts
      layouts:
        - "2006-01-02T15:04:05.000Z07:00"
      target_field: "@timestamp"
```

### 4.3 samples.log

样例日志用于提供字段候选值、数字范围、JSON 结构和默认分布。

```text
2026-05-15T10:00:00.000+08:00 INFO app=order-service trace=aaa0000000000001 ip=10.12.3.4 method=POST path=/api/order status=200 latency=34 payload={"order_id":"7e4f4e7e-8f6a-4b3d-9ad4-8e4728a70a11","amount":1688,"region":"cn"}
2026-05-15T10:00:00.001+08:00 INFO app=order-service trace=aaa0000000000002 ip=10.12.3.5 method=GET path=/api/order status=200 latency=41 payload={"order_id":"51f5d7cd-93da-4e8d-938c-094d968c7a2a","amount":203,"region":"cn"}
2026-05-15T10:00:00.002+08:00 WARN app=order-service trace=aaa0000000000003 ip=10.44.1.9 method=GET path=/api/pay status=400 latency=289 payload={"order_id":"350332c6-1927-4301-98ee-2986eb55e6fd","amount":9301,"region":"us"}
2026-05-15T10:00:00.003+08:00 ERROR app=order-service trace=aaa0000000000004 ip=10.33.77.8 method=POST path=/api/pay status=500 latency=2450 payload={"order_id":"178a31c9-69d6-4742-83ef-40f7d3d39722","amount":5110,"region":"cn"}
```

### 4.4 dimensions.yml 可选

汇聚维度用于提高随机日志分布的准确率，不描述日志格式。

```yaml
version: v1

dimensions:
  - field: path
    required: true
    values:
      - value: /api/order
        weight: 70
      - value: /api/pay
        weight: 20
      - value: /api/user
        weight: 10

  - field: status
    required: true
    values:
      - value: "200"
        weight: 95
      - value: "400"
        weight: 3
      - value: "500"
        weight: 2

  - field: trace_id
    cardinality: per_event

  - field: payload.order_id
    cardinality: per_event
```

---

## 5. 同语法删减规则

业务只做删除，不改写成新 DSL。

### 5.1 必须保留

| processor | 保留原因 |
|-----------|----------|
| `dissect` | 描述原始日志文本结构 |
| `decode_json_fields` | 标记哪些字段是 JSON 字符串 |
| `timestamp` | 标记业务时间字段和 layout |
| `decode_csv_fields` | 原始字段是 CSV 时保留 |
| `syslog` | 原始日志是 syslog 时保留 |
| `decode_cef` | 原始日志是 CEF 时保留 |
| `parse_aws_vpc_flow_log` | 原始日志是 AWS VPC Flow 时保留 |

### 5.2 必须删除

| processor | 删除原因 |
|-----------|----------|
| `drop_event` | 改变事件数量，不能作为生成依据 |
| `script` | 任意逻辑，不允许作为生成依据 |
| `dns` | 外部依赖，不稳定 |
| metadata 类 | 依赖运行环境，不描述原始日志 |
| `rate_limit` | 流控行为，不属于日志格式 |
| `drop_fields` / `include_fields` | 解析后字段清理，不影响原始日志 |
| `add_tags` / `add_labels` | 不影响原始日志 |

### 5.3 建议删除

| processor | 处理方式 |
|-----------|----------|
| `convert` | 生成器生成可转换的数字字符串；完整压测仍由 full 执行 |
| `rename` / `copy_fields` | 除非后续保留的解析算子依赖，否则删除 |
| `replace` | 优先让样例日志已经是可解析形态 |
| `lowercase` / `uppercase` | 样例中直接给目标大小写 |
| `if/then/else` | 默认删除；分支比例通过样例或 dimensions 表达 |

### 5.4 工具校验

工具应直接检查删减结果，而不是只依赖文档约定。

失败条件：

- `processors.generate.yml` 出现 `drop_event`、`script`、`dns`、`rate_limit`。
- 没有任何可识别解析算子。
- 样例日志不能被 `processors.generate.yml` 解析。
- 生成样本不能通过 `processors.full.yml` 预校验。

警告条件：

- `processors.generate.yml` 出现 `drop_fields`、`add_tags`、metadata、`rename`、`copy_fields`。
- 样例数量少于 20 行。
- 没有提供汇聚维度，且字段候选值明显不足。

---

## 6. 生成计划编译

工具内部可以编译出生成计划，但不暴露给业务。

```text
processors.generate.yml + samples.log + dimensions.yml + run 参数
        ↓
解析 dissect tokenizer / syslog / cef / csv / timestamp 配置
        ↓
用样例日志提取字段值
        ↓
识别字段类型：timestamp / enum / int / float / ip / uuid / json / string
        ↓
用 dimensions 覆盖关键字段候选值、权重和高基数
        ↓
生成内部 plan
```

关键规则：

- `processors.generate.yml` 决定字段结构。
- `samples.log` 决定默认候选值和类型。
- `dimensions.yml` 决定关键字段分布和基数。
- 如果三者冲突，默认失败。

---

## 7. 时间与 TPS

TPS 定义为逻辑事件数/秒，不是物理行数/秒。

运行参数示例：

```powershell
fbcap run `
  --filebeat .\filebeat.exe `
  --processors-full processors.full.yml `
  --processors-generate processors.generate.yml `
  --samples samples.log `
  --dimensions dimensions.yml `
  --qps 1000,3000,5000 `
  --duration 10m `
  --warmup 1m `
  --time-field ts `
  --start-time "2026-05-15T10:00:00+08:00" `
  --time-step auto
```

`--time-step auto`：

```text
step = 1s / qps
event_time(n) = start_time + n * step
```

如果 QPS 为 1000，则每条日志时间递增 1ms。

写入要求：

- 实际 TPS 与目标 TPS 偏差超过 1% 时失败。
- writer lag 超过阈值时失败。
- 每个 QPS 点使用独立 run 目录和独立 Filebeat `path.data`。

---

## 8. Multiline

第一版只支持三类，保证简单可靠。

| 模式 | 说明 |
|------|------|
| `none` | 每条事件一行 |
| `count` | 每条事件固定 N 行 |
| `indent_stack` | 堆栈日志，首行非空白，续行以空白开头 |

`indent_stack` 对应 Filebeat 配置由工具固定生成：

```yaml
parsers:
  - multiline:
      type: pattern
      pattern: '^\s'
      match: after
```

业务不需要写复杂 multiline 正则。需要更复杂 multiline 时，进入后续版本。

---

## 9. 汇聚维度增强

汇聚维度能显著提高生成准确率，尤其是枚举值、权重和高基数字段。

合并优先级：

| 来源 | 优先级 | 用途 |
|------|--------|------|
| `processors.generate.yml` | 最高 | 决定字段结构 |
| `dimensions.yml` | 高 | 决定关键字段候选值、权重、基数 |
| `samples.log` | 中 | 决定默认候选值、类型、JSON 结构 |
| 工具推断 | 低 | 只在前面都缺失时使用 |

高基数字段建议显式声明：

```yaml
dimensions:
  - field: trace_id
    cardinality: per_event
  - field: tenant_id
    cardinality: 1000
```

预校验必须检查：

- `required: true` 的维度最终存在。
- 维度分布接近权重。
- 高基数字段 distinct count 达标。

---

## 10. 预校验闸门

容量压测前必须强制预校验。

步骤：

1. 校验 `processors.full.yml`、`processors.generate.yml`、`samples.log`、可选 `dimensions.yml`。
2. 用 `processors.generate.yml` 解析样例，编译生成计划。
3. 生成至少 10000 条预校验日志。
4. 启动真实 Filebeat，执行 `processors.full.yml`，输出到 `output.discard`。
5. 等待 ack 并采集 Filebeat 日志与 `/stats`。
6. 校验无 processor error。
7. 校验 generated / acked / dropped 事件数符合预期。
8. 校验维度存在率、分布和基数。
9. 校验 writer TPS 和 writer lag。

任一步失败都不进入压测。

---

## 11. Filebeat 运行配置

工具生成临时 `filebeat.yml`。

```yaml
filebeat.inputs:
  - type: filestream
    id: capacity-${run_id}
    paths:
      - ${input_dir}/*.log

processors:
  # 注入 processors.full.yml

output.discard: {}

http.enabled: true
http.host: 127.0.0.1
http.port: ${free_port}

path.data: ${run_dir}/data
path.logs: ${run_dir}/logs
logging.level: error
```

说明：

- 默认使用 `filestream`。
- 默认使用 `output.discard`，隔离下游成本。
- 每个 QPS 点使用独立 `path.data`，避免 registry 污染。

---

## 12. 资源采集口径

默认只统计 Filebeat 进程自身，不包含日志生成器、控制器和下游服务。

必须采集：

| 资源 | 口径 |
|------|------|
| CPU | Filebeat 进程 CPU 时间差分，换算为 CPU cores |
| 内存 | Filebeat 进程 RSS / Working Set |
| 磁盘 IO | Filebeat 进程读写字节和操作次数 |
| 文件句柄 | Filebeat 进程打开文件数 |
| 线程数 | Filebeat 进程线程数 |

建议采集：

| 资源 | 口径 |
|------|------|
| Go heap | Filebeat `/stats` |
| Pipeline / Queue | Filebeat `/stats` |
| 网络 IO | 仅在能保证进程级采集时报告 |

网络口径：

- 默认 `output.discard` 时网络应接近 0。
- 工具轮询 Filebeat localhost `/stats` 的流量不计入 output 成本。
- 如果无法可靠获取进程级网络字节数，报告必须写 `network: unsupported`，不能用整机网卡流量替代。

---

## 13. 报告

报告分两类：事实指标和资源建议。

事实指标：

```yaml
scenario: order-service
filebeat_version: 8.x
processors_full_hash: xxx
processors_generate_hash: yyy
samples_count: 100
dimensions_hash: zzz

results:
  - qps: 3000
    actual_qps: 2998.9
    acked_qps: 2998.9
    cpu_cores_p95: 1.18
    rss_mb_p95: 240
    disk_read_mb: 8200
    disk_write_mb: 45
    writer_lag_p95_ms: 5
    queue_fill_p95: 0.12
    drop_rate: 0
    stable: true
```

资源建议：

```yaml
recommendation:
  max_stable_qps_per_instance: 3000
  recommended_cpu_cores: 2
  recommended_memory_mb: 512
```

报告必须标注：

- Filebeat 版本。
- full/generate processors hash。
- 样例数量。
- 是否使用 dimensions。
- 是否存在外部依赖 processor。
- 资源是否为 Filebeat 进程自身口径。
- 网络采集是否 supported。

---

## 14. 解析算子覆盖范围

第一版覆盖最高频主路径：

| 算子 | 第一版支持 | 说明 |
|------|------------|------|
| `dissect` | 是 | 固定格式文本日志 |
| `decode_json_fields` | 是 | 文本日志中嵌 JSON |
| `timestamp` | 是 | 连续时间字段 |
| `convert` | 间接支持 | generate 中删除，full 中真实执行 |
| multiline `none/count/indent_stack` | 是 | 常见单行和堆栈日志 |

后续扩展顺序：

1. `decode_csv_fields`、`decode_base64_field`、`urldecode`、`decode_duration`。
2. `syslog`、`decode_cef`、`parse_aws_vpc_flow_log`。
3. `decode_xml`、`decode_xml_wineventlog`、`decompress_gzip_field`、`detect_mime_type`。

原则：完整 `processors.full.yml` 可以包含所有 processor；只是生成依据的 `processors.generate.yml` 第一版只接受稳定子集。

---

## 15. 示例：从复杂配置到生成日志

### 15.1 full 到 generate

业务从完整生产配置中删除 `convert`、`if/then/else`、`drop_event`、`drop_fields`，只保留：

```yaml
processors:
  - dissect:
      tokenizer: "%{ts} %{level} app=%{app} trace=%{trace_id} ip=%{client_ip} method=%{method} path=%{path} status=%{status} latency=%{latency_ms} payload=%{payload}"
      field: message
      target_prefix: ""
      overwrite_keys: true
  - decode_json_fields:
      fields: ["payload"]
      target: "payload"
      overwrite_keys: true
  - timestamp:
      field: ts
      layouts:
        - "2006-01-02T15:04:05.000Z07:00"
      target_field: "@timestamp"
```

### 15.2 生成的 10 行日志

假设 QPS 为 1000，`time-step=auto`，时间每条递增 1ms。

```text
2026-05-15T10:00:00.000+08:00 INFO app=order-service trace=aaa0000000000001 ip=10.12.3.4 method=POST path=/api/order status=200 latency=34 payload={"order_id":"7e4f4e7e-8f6a-4b3d-9ad4-8e4728a70a11","amount":1688,"region":"cn"}
2026-05-15T10:00:00.001+08:00 INFO app=order-service trace=aaa0000000000002 ip=10.12.3.5 method=GET path=/api/order status=200 latency=41 payload={"order_id":"51f5d7cd-93da-4e8d-938c-094d968c7a2a","amount":203,"region":"cn"}
2026-05-15T10:00:00.002+08:00 WARN app=order-service trace=aaa0000000000003 ip=10.44.1.9 method=GET path=/api/pay status=400 latency=289 payload={"order_id":"350332c6-1927-4301-98ee-2986eb55e6fd","amount":9301,"region":"us"}
2026-05-15T10:00:00.003+08:00 ERROR app=order-service trace=aaa0000000000004 ip=10.33.77.8 method=POST path=/api/pay status=500 latency=2450 payload={"order_id":"178a31c9-69d6-4742-83ef-40f7d3d39722","amount":5110,"region":"cn"}
2026-05-15T10:00:00.004+08:00 INFO app=order-service trace=aaa0000000000005 ip=10.101.2.33 method=GET path=/api/user status=200 latency=18 payload={"order_id":"79a4df92-a6bb-4419-8f63-108cae50f379","amount":61,"region":"eu"}
2026-05-15T10:00:00.005+08:00 INFO app=order-service trace=aaa0000000000006 ip=10.6.5.19 method=GET path=/api/order status=200 latency=56 payload={"order_id":"ea626a2d-f8c2-4f25-8180-2c2227f61d4a","amount":900,"region":"cn"}
2026-05-15T10:00:00.006+08:00 INFO app=order-service trace=aaa0000000000007 ip=10.88.42.3 method=POST path=/api/order status=200 latency=91 payload={"order_id":"e2962a55-bf58-4f7e-a8e6-3e39e7104e96","amount":4320,"region":"cn"}
2026-05-15T10:00:00.007+08:00 WARN app=order-service trace=aaa0000000000008 ip=10.22.16.71 method=GET path=/api/pay status=400 latency=150 payload={"order_id":"c36488be-c635-4143-889d-2fd28c2e4922","amount":728,"region":"us"}
2026-05-15T10:00:00.008+08:00 INFO app=order-service trace=aaa0000000000009 ip=10.9.200.44 method=GET path=/api/order status=200 latency=27 payload={"order_id":"ff78cf73-0ec7-40d1-9cb8-45f6fdce24a0","amount":384,"region":"cn"}
2026-05-15T10:00:00.009+08:00 ERROR app=order-service trace=aaa0000000000010 ip=10.55.19.88 method=POST path=/api/user status=500 latency=3100 payload={"order_id":"4c0361ec-0aa6-4f31-99e3-61dd2de03f2c","amount":9912,"region":"eu"}
```

这些日志应满足：

- 能被 generate 中的 `dissect` 解析。
- `payload` 是合法 JSON。
- `ts` 能被 `timestamp` layout 解析。
- `status`、`latency` 在 full 中可被 `convert` 转换。
- 维度 `path/status/region` 覆盖业务声明。

---

## 16. Go 实现模块

```text
cmd/fbcap/
internal/config/          # run 参数、文件加载
internal/processors/      # generate processors 校验和解析
internal/infer/           # 从 samples 和 dimensions 推断候选值/类型/分布
internal/generator/       # 内部生成计划和日志渲染
internal/writer/          # TPS 调度和文件写入
internal/filebeat/        # 临时 filebeat.yml、启动、停止、stats、日志采集
internal/metrics/         # 进程 CPU/内存/磁盘/网络采样
internal/benchmark/       # preflight、qps run、稳定性判定
internal/report/          # markdown/json 报告
```

MVP 验收：

1. 同一输入同一 seed 生成结果可复现。
2. 预校验 100% 通过才运行压测。
3. QPS 偏差小于 1%。
4. 时间字段严格连续。
5. CPU、内存、磁盘 IO 是 Filebeat 进程自身口径。
6. writer lag、Filebeat error、drop rate 超范围都会失败。
7. 输出 JSON 和 Markdown 报告。

---

## 17. 附录说明

下面附录保留 Beats 源码和 processor 行为分析，用于后续实现时查细节。正文方案以上方第 1 到 16 节为准。

---
## 附录 A：Processor 核心架构

### Processor 接口

定义在 `libbeat/beat/pipeline.go`，极简设计：

```go
type Processor interface {
    Run(in *Event) (*Event, error)  // 返回 nil = 丢弃事件
    String() string
}
```

可选扩展接口（通过 Go 接口断言实现鸭子类型）：
- **Closer**：`Close() error`，释放资源
- **PathSetter**：`SetPaths(*paths.Path) error`，延迟路径初始化

### 数据流

```
Input → Client → [Processors链] → Queue → Consumer → Output(Elasticsearch等)
```

处理器在 Client 的 goroutine 中同步串行执行，在进入 Queue 之前完成。

### 注册机制

- 每个 Processor 通过 `init()` + `RegisterPlugin()` 自注册到全局 `Namespace`（树形注册表）
- 所有处理器被 `NewConditional` 装饰器自动包装，天然支持 `when` 条件
- 被两层包装：`NewConditional`（条件支持）+ `SafeWrap`（线程安全）

### 处理管线（11步固定顺序）

通过 Builder 模式组装，合并全局（Pipeline级）和局部（Client级）配置：

1. 事件规范化
2. Meta/Fields 注入
3. 客户端处理器
4. ECS 字段
5. 管线级处理器
6. ... → 时序处理 → 输出

### 条件处理

支持 `when`（单条件）、`if/then/else`（分支）、递归组合（`and`/`or`/`not`）

---

## 附录 B：14 个解析解码类算子分析

### 3.1 dissect — 按 tokenizer 模式提取

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\dissect\config.go
D:\beats-main\beats-main\libbeat\processors\dissect\processor.go
D:\beats-main\beats-main\libbeat\processors\dissect\dissect.go
D:\beats-main\beats-main\libbeat\processors\dissect\const.go
D:\beats-main\beats-main\libbeat\processors\dissect\delimiter.go
D:\beats-main\beats-main\libbeat\processors\dissect\field.go
D:\beats-main\beats-main\libbeat\processors\dissect\parser.go
D:\beats-main\beats-main\libbeat\processors\dissect\trim.go
D:\beats-main\beats-main\libbeat\processors\dissect\validate.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `tokenizer` | string | 必填 | dissect 模板字符串 |
| `field` | string | `"message"` | 要 dissect 的事件字段名 |
| `target_prefix` | string | `"dissect"` | 提取结果前缀 |
| `ignore_failure` | bool | `false` | 解析失败时静默忽略 |
| `overwrite_keys` | bool | `false` | 允许覆盖已有字段 |
| `trim_values` | string | `"none"` | 裁剪模式：none/left/right/all/both |
| `trim_chars` | string | `" "` | 裁剪字符集 |

**修饰符**：

| 前缀 | 语法 | 作用 |
|------|------|------|
| _(无)_ | `%{key}` | 普通字段，提取值直接存入 map |
| _(空key)_ | `%{}` | 跳过字段，提取值但不保存 |
| `?` | `%{?key}` | 命名跳过字段（已弃用，推荐用 `*`） |
| `*` | `%{*key}` | 指针字段，提取值作为间接字段的 key |
| `+` | `%{+key}` | 追加字段，多次出现同名 key 时值追加 |
| `&` | `%{&key}` | 间接字段，从 map 中取出 key 对应的值作为真正的 key 名 |

**后缀**：

| 后缀 | 语法 | 作用 |
|------|------|------|
| `/N` | `%{+key/2}` | 追加字段排序序号 |
| `#N` | `%{key#5}` | 固定字节长度 |
| `->` | `%{key->}` | 贪婪匹配 |
| `\|type` | `%{key\|integer}` | 类型转换：integer/long/float/double/string/boolean/ip |

**反推日志格式**：tokenizer 本身就是格式模板，直接填充随机值即可。

**边界注意**：
- 首分隔符必须精确匹配行首
- 固定长度字段必须恰好 N 字节
- 追加字段的连接符是分隔符文本而非固定空格
- 追加字段的序号决定拼接顺序（不一定按出现顺序）
- 类型转换失败时静默回退为原始字符串
- `DissectConvert`（有类型转换时）不执行 trim

---

### 3.2 decode_json_fields — JSON 字符串解码

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\actions\decode_json_fields.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `fields` | []string | 必填 | 要解码的字段列表 |
| `target` | *string | nil | 解析结果写入的目标字段 |
| `max_depth` | int | `1` | 最大递归解码深度 |
| `overwrite_keys` | bool | `false` | 覆盖已有键 |
| `add_error_key` | bool | `false` | 解析失败时添加 error 字段 |
| `process_array` | bool | `false` | 处理 JSON 数组内的元素 |
| `document_id` | string | `""` | 提取文档 ID 的字段名 |
| `expand_keys` | bool | `false` | 展开点号分隔的键 |

**反推日志格式**：配置说明哪些字段含 JSON，JSON 内部键名/结构需从示范日志推断。

**边界注意**：
- `target=""`（展开到根）与不配 `target`（原地替换）行为完全不同
- `process_array=false` 且 `max_depth>1` 时遇到数组会失败
- 不支持多 JSON 元素（如 `{"a":1}{"b":2}`）
- `document_id` 指定的键会从结果中被删除
- 使用 `json.Decoder.UseNumber()` 保证数字精度
- 部分字段解码失败不影响其他字段

---

### 3.3 decode_csv_fields — CSV 解析

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\decode_csv_fields\decode_csv_fields.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `fields` | map | 必填 | key=源字段路径, value=目标字段路径 |
| `separator` | string | `","` | CSV 分隔符（单个字符） |
| `ignore_missing` | bool | `false` | 字段不存在时静默忽略 |
| `overwrite_keys` | bool | `false` | 允许覆盖已有键 |
| `trim_leading_space` | bool | `false` | 去除前导空格 |
| `fail_on_error` | bool | `true` | 解析失败时报错 |

**反推日志格式**：知道分隔符和源字段，但各列含义需从示范日志推断（结果是 `[]string` 数组）。

**边界注意**：
- 只解析第一行 CSV
- `LazyQuotes=true` 硬编码
- Go map 遍历顺序随机（多字段映射顺序不确定）
- 多字段映射失败时回滚到备份 event

---

### 3.4 decode_xml — 通用 XML 解析

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\decode_xml\decode_xml.go
D:\beats-main\beats-main\libbeat\processors\decode_xml\config.go
D:\beats-main\beats-main\libbeat\common\encoding\xml\decode.go
D:\beats-main\beats-main\libbeat\common\encoding\xml\safe_reader.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `field` | string | `"message"` | 源字段名 |
| `target_field` | *string | 覆盖源字段 | 目标字段名 |
| `overwrite_keys` | bool | `true` | 覆盖已有键 |
| `document_id` | string | `""` | 提取文档 ID 的键路径 |
| `to_lower` | bool | `true` | 键名转小写 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `ignore_failure` | bool | `false` | 解析失败静默跳过 |

**反推日志格式**：知道源字段是 XML，但 XML schema 需从示范日志推断。

**边界注意**：
- `SafeReader` 预处理过滤 UTF 控制字符
- 同名 XML 元素自动变数组
- XML 属性与子元素平铺到同层 map
- 编码声明被忽略，数据应已是 UTF-8

---

### 3.5 decode_xml_wineventlog — Windows 事件日志 XML

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\decode_xml_wineventlog\processor.go
D:\beats-main\beats-main\libbeat\processors\decode_xml_wineventlog\config.go
D:\beats-main\beats-main\libbeat\processors\decode_xml_wineventlog\decoder.go
D:\beats-main\beats-main\libbeat\processors\decode_xml_wineventlog\decoder_windows.go
D:\beats-main\beats-main\winlogbeat\sys\winevent\event.go
D:\beats-main\beats-main\winlogbeat\sys\winevent\winmeta.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `field` | string | `"message"` | 源字段名 |
| `target_field` | string | `"winlog"` | 目标字段名 |
| `overwrite_keys` | bool | `true` | 覆盖已有键 |
| `map_ecs_fields` | bool | `true` | 映射 ECS 标准字段 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `ignore_failure` | bool | `false` | 解析失败静默跳过 |
| `language` | uint32 | `0` | Windows 语言区域 ID |

**反推日志格式**：完全固定，严格遵循 Windows Event Log XML Schema。

**XML 结构**：

```xml
<Event>
  <System>
    <Provider Name="..." Guid="..."/>
    <EventID>数字</EventID>
    <Version>数字</Version>
    <Level>数字</Level>
    <Task>数字</Task>
    <Keywords>十六进制</Keywords>
    <TimeCreated SystemTime="RFC3339Nano"/>
    <Channel>通道名</Channel>
    <Computer>计算机名</Computer>
    <EventRecordID>数字</EventRecordID>
    <Security UserID="SID"/>
  </System>
  <EventData>
    <Data Name="键名">值</Data>
  </EventData>
  <RenderingInfo>
    <Message>消息</Message>
    <Level>级别名</Level>
    <Keywords><Keyword>关键字</Keyword></Keywords>
  </RenderingInfo>
</Event>
```

**边界注意**：
- Keywords 位掩码：bit52=failure(Audit Failure), bit53=success(Audit Success)
- EventData 空名键自动命名 `paramN`（从 1 开始）
- Windows 平台有 publisher metadata 缓存
- ECS 映射：`event.code`, `event.kind`, `event.provider`, `event.action`, `host.name` 等

---

### 3.6 syslog — RFC3164/RFC5424 解析

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\syslog\syslog.go
D:\beats-main\beats-main\libbeat\reader\syslog\message.go
D:\beats-main\beats-main\libbeat\reader\syslog\syslog.go
D:\beats-main\beats-main\libbeat\reader\syslog\parser\rfc3164.rl
D:\beats-main\beats-main\libbeat\reader\syslog\parser\rfc5424.rl
D:\beats-main\beats-main\libbeat\reader\syslog\rfc3164_gen.go
D:\beats-main\beats-main\libbeat\reader\syslog\rfc5424_gen.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `field` | string | `"message"` | 源字段名 |
| `format` | string | `"auto"` | auto/rfc3164/rfc5424 |
| `timezone` | timezone | 本地时区 | RFC3164 时间戳补时区 |
| `overwrite_keys` | bool | `true` | 覆盖已有键 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `ignore_failure` | bool | `false` | 解析失败静默跳过 |

**格式自动检测**：通过 `<数字>数字 空格 4位数字` 判断 RFC5424，否则走 RFC3164。

**RFC3164 格式**：

```
<PRIORITY>MONTH DAY HH:MM:SS HOSTNAME TAG[PID]: MESSAGE
```

示例：`<34>Jan 12 08:33:22 myhost sshd[12345]: Accepted publickey`

- priority 可选
- 时间戳：BSD 格式（`Jan  2 15:04:05`）或 RFC3339
- tag 不能含空格/冒号/方括号
- BSD 时间戳缺年份，取当前年

**RFC5424 格式**：

```
<PRIORITY>VERSION TIMESTAMP HOSTNAME APP-NAME PROC-ID MSG-ID STRUCTURED-DATA [SP MESSAGE]
```

示例：`<34>1 2024-01-12T08:33:22.123Z myhost myapp 12345 ID47 [exampleSDID@32473 iut="3"] test`

- priority 必填
- Structured Data：`[SD-ID PARAM-NAME="PARAM-VALUE" ...]`
- 转义：`\"`→`"`, `\]`→`]`, `\\`→`\`
- nil value 用 `-` 表示

**输出字段**：`log.syslog.priority`, `log.syslog.facility.code/name`, `log.syslog.severity.code/name`, `log.syslog.appname`, `log.syslog.procid`, `log.syslog.hostname`, `log.syslog.msgid`(仅5424), `log.syslog.version`(仅5424), `log.syslog.structured_data`(仅5424)

---

### 3.7 decode_base64_field — Base64 解码

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\actions\decode_base64_field.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `field.from` | string | 必填 | 源字段名 |
| `field.to` | string | 等于 from | 目标字段名 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `fail_on_error` | bool | `true` | 失败时报错 |

**边界注意**：使用 `RawStdEncoding`（非 URL-safe）；自动去除尾部 `=`；只接受 string 类型

---

### 3.8 decode_duration — Go 时长解析

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\decode_duration\decode_duration.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `field` | string | 必填 | 源字段名 |
| `format` | string | 必填 | milliseconds/seconds/minutes/hours |

**反推日志格式**：字段一定是 Go duration 格式（如 `"1h30m"`, `"500ms"`）。

**边界注意**：不支持 `d`/`w` 单位；原地替换为 float64；无 ignore 选项

---

### 3.9 urldecode — URL 解码

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\urldecode\urldecode.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `fields` | []fromTo | 必填 | 源→目标字段映射数组 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `fail_on_error` | bool | `true` | 失败时报错 |

**边界注意**：使用 `url.QueryUnescape`，`+` 变空格；多字段失败时回滚

---

### 3.10 decompress_gzip_field — Gzip 解压

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\actions\decompress_gzip_field.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `field.from` | string | 必填 | 源字段名 |
| `field.to` | string | 必填 | 目标字段名 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `fail_on_error` | bool | `true` | 失败时报错 |

**边界注意**：输入支持 string 和 []byte；输出为 string；存在解压炸弹风险

---

### 3.11 timestamp — 时间戳解析转换

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\timestamp\timestamp.go
D:\beats-main\beats-main\libbeat\processors\timestamp\config.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `field` | string | 必填 | 源字段名 |
| `layouts` | []string | 必填 | 时间格式模板列表 |
| `target_field` | string | `"@timestamp"` | 目标字段名 |
| `timezone` | timezone | UTC | 时区 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `ignore_failure` | bool | `false` | 解析失败静默跳过 |

**特殊 layout**：`"UNIX"`(秒), `"UNIX_MS"`(毫秒)；其他用 Go 标准格式

**反推日志格式**：layouts 精确定义时间格式

**边界注意**：按序尝试 layouts 返回首个成功；年份为 0 时补当前年；已是 time.Time 直接跳过

---

### 3.12 detect_mime_type — MIME 类型检测

**源文件**：

```
D:\beats-main\beats-main\libbeat\processors\actions\detect_mime_type.go
```

**配置**：`field`(必填), `target`(必填)

**反推日志格式**：不能反推。通过 magic bytes 检测内容类型。所有错误静默跳过。

---

### 3.13 decode_cef (X-Pack) — CEF 公共事件格式

**源文件**：

```
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\decode_cef.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\config.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\keys.ecs.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\cef.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\parser.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\keys.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\types.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\option.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `field` | string | `"message"` | 源字段名 |
| `target_field` | string | `"cef"` | 目标字段名 |
| `ecs` | bool | `true` | 启用 ECS 映射 |
| `timezone` | timezone | UTC | 时区 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `ignore_failure` | bool | `false` | 解析失败静默跳过 |
| `ignore_empty_values` | bool | `false` | 忽略空值 |

**CEF 格式**：

```
CEF:Version|Device Vendor|Device Product|Device Version|Device Event Class ID|Name|Severity|[Extension]
```

示例：`CEF:0|Security|IDS|1.0|100|Attack Detected|7|src=10.0.0.1 dst=10.0.0.2 spt=1234 dpt=80 proto=TCP`

**反推日志格式**：完全固定。以 `CEF:` 开头，`|` 分隔 7 个头字段，空格分隔 `key=value` 扩展。

**边界注意**：
- `|` 用 `\|` 转义，`\` 用 `\\` 转义
- 支持 150+ 标准扩展键缩写（`src`→`sourceAddress`, `dst`→`destinationAddress`）
- ECS 映射约 70+ 个字段
- Extension 中 `=` 需用 `\=` 转义
- 支持 `\n` 和 `\r` 转义序列

---

### 3.14 parse_aws_vpc_flow_log (X-Pack) — AWS VPC 流日志

**源文件**：

```
D:\beats-main\beats-main\x-pack\filebeat\processors\aws_vpcflow\parse_aws_vpc_flow_log.go
D:\beats-main\beats-main\x-pack\filebeat\processors\aws_vpcflow\config.go
D:\beats-main\beats-main\x-pack\filebeat\processors\aws_vpcflow\mapping.go
D:\beats-main\beats-main\x-pack\filebeat\processors\aws_vpcflow\types.go
```

**配置**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `format` | string/[]string | 必填 | 字段顺序模板 |
| `mode` | string | `"ecs"` | original/ecs/ecs_and_original |
| `field` | string | `"message"` | 源字段名 |
| `target_field` | string | `"aws.vpcflow"` | 目标字段名 |
| `ignore_missing` | bool | `false` | 字段不存在静默跳过 |
| `ignore_failure` | bool | `false` | 解析失败静默跳过 |

**反推日志格式**：完全固定。空格分隔，按字段数量自动匹配 format 版本（v2 有 14 字段，到 v8 有 55 字段）。

示例：`2 123456789012 eni-abc123 10.0.0.1 10.0.0.2 12345 80 6 10 500 1672531200 1672531260 ACCEPT OK`

**边界注意**：
- 无数据字段用 `-`
- IP 类型需合法 IP
- 时间字段是 Unix 秒
- action 只能 `ACCEPT`/`REJECT`
- protocol 是 IANA 协议号（6=TCP, 17=UDP）
- tcp_flags 是位掩码（0x02=SYN, 0x10=ACK, 0x12=SYN+ACK）

---

### 反推格式能力总结

| 能力等级 | 算子 |
|---------|------|
| **完全反推**（格式固定） | dissect, decode_cef, parse_aws_vpc_flow_log, decode_xml_wineventlog, syslog |
| **部分反推**（需示范日志补充） | decode_json_fields, decode_csv_fields, decode_xml, decode_base64_field, urldecode, decompress_gzip_field, decode_duration, timestamp |
| **无法反推** | detect_mime_type |

---

## 附录 C：Multiline 组件分析

### 源文件

```
D:\beats-main\beats-main\libbeat\reader\multiline\multiline.go
D:\beats-main\beats-main\libbeat\reader\multiline\multiline_config.go
D:\beats-main\beats-main\libbeat\reader\multiline\pattern.go
D:\beats-main\beats-main\libbeat\reader\multiline\counter.go
D:\beats-main\beats-main\libbeat\reader\multiline\while.go
D:\beats-main\beats-main\libbeat\reader\multiline\message_buffer.go
D:\beats-main\beats-main\libbeat\reader\parser\parser.go
```

### 完整配置

| 字段 | 默认值 | 适用模式 | 说明 |
|------|--------|---------|------|
| `type` | `pattern` | 全部 | pattern/count/while_pattern |
| `pattern` | 必填 | pattern, while_pattern | 正则表达式 |
| `match` | 必填 | 仅 pattern | after/before |
| `negate` | `false` | pattern, while_pattern | 匹配结果取反 |
| `flush_pattern` | 无 | 仅 pattern | 提前终止的正则 |
| `count_lines` | 必填 | 仅 count | 每条事件固定行数 |
| `max_lines` | `500` | pattern, while_pattern | 单条事件最大行数 |
| `timeout` | `5s` | pattern, while_pattern | 无新行超时自动输出 |
| `skip_newline` | `false` | 全部 | 行间不加换行符直接拼接 |

### 模式一：pattern（最常用）

**逻辑**：通过正则判断当前行是"新事件起始"还是"上一条的续行"

- `match: after` → 正则匹配**当前行**，匹配则归入上一条
- `match: before` → 正则匹配**上一行**，匹配则当前行归入上一条
- `negate: true` → 匹配结果取反
- `flush_pattern` → 当前行匹配此正则时，追加后立即输出

**典型场景：Java 堆栈跟踪**

```yaml
multiline:
  type: pattern
  pattern: '^\s'       # 以空白开头的是续行
  match: after          # 追加到上一条
```

生成日志示例：

```
2024-01-15 ERROR Something failed
  at com.foo.Bar.doSomething(Bar.java:42)
  at com.foo.Baz.main(Baz.java:15)
2024-01-15 INFO Normal log
```

### 模式二：count（纯计数）

**逻辑**：每 `count_lines` 行聚合为一条事件，不做正则匹配。没有 timeout，行数不够时会阻塞。

**典型场景：固定格式设备日志**

```yaml
multiline:
  type: count
  count_lines: 3
```

生成日志示例：

```
2024-01-15 10:00:00           ← 事件1行1
DATA: 0x1A 0x2B 0x3C 0x4D    ← 事件1行2
CHECKSUM: 0x9F               ← 事件1行3 → 输出
```

### 模式三：while_pattern（连续同类行）

**逻辑**：只看当前行本身是否匹配 pattern，连续匹配的行聚合，遇到不匹配立即结束。

**典型场景：带标签的调试日志**

```yaml
multiline:
  type: while_pattern
  pattern: '^TRACE'
```

生成日志示例：

```
TRACE start processing
TRACE step 1 done
TRACE step 2 done
INFO normal log             ← 不匹配 → 事件输出，此行单独输出
```

### 三种模式对比

| | pattern | count | while_pattern |
|---|---------|-------|---------------|
| 判定依据 | 正则(last+current) | 固定行数 | 正则(仅current) |
| timeout | 支持 | 不支持 | 支持 |
| flush_pattern | 支持 | 不支持 | 不支持 |
| negate | 支持 | 不适用 | 支持 |
| 适用场景 | 通用多行(堆栈等) | 固定行数 | 连续同类行 |

### 对日志生成器的影响

1. **pattern 模式**：续行写入间隔不能超过 timeout（默认 5s）；续行必须符合 pattern，首行必须不符合（或反过来，取决于 negate）
2. **count 模式**：每条日志恰好 count_lines 行，必须连续写入；文件结尾要恰好对齐
3. **while_pattern 模式**：同类行必须连续，不同类行之间自然分隔；续行写入间隔不能超过 timeout
4. **通用**：max_lines 超出截断并标记 `log.flags: "truncated"`；max_bytes 默认 10MB 超出同样截断

---

## 附录 D：完整算子清单（54 个）

### 解析/解码类（14 个）

| 算子 | 许可 | 作用 |
|------|------|------|
| dissect | 开源 | 按 tokenizer 模式提取字段 |
| decode_json_fields | 开源 | JSON 字符串解码 |
| decode_csv_fields | 开源 | CSV 解析 |
| decode_xml | 开源 | XML 解析 |
| decode_xml_wineventlog | 开源 | Windows 事件日志 XML |
| decode_base64_field | 开源 | Base64 解码 |
| decode_duration | 开源 | Go 时间段解析 |
| decode_cef | X-Pack | CEF 公共事件格式 |
| parse_aws_vpc_flow_log | X-Pack | AWS VPC 流日志 |
| syslog | 开源 | RFC3164/RFC5424 解析 |
| urldecode | 开源 | URL 解码 |
| decompress_gzip_field | 开源 | Gzip 解压 |
| timestamp | 开源 | 时间戳格式解析转换 |
| detect_mime_type | 开源 | MIME 类型检测 |

### 字段变换类（9 个）

| 算子 | 作用 |
|------|------|
| rename | 字段重命名 |
| copy_fields | 复制字段 |
| move_fields | 移动字段层级 |
| replace | 正则替换字段值 |
| lowercase | 转小写 |
| uppercase | 转大写 |
| truncate_fields | 截断字段 |
| convert | 类型转换 |
| extract_array | 从数组提取元素 |

### 字段增删类（8 个）

| 算子 | 作用 |
|------|------|
| add_fields | 添加自定义字段 |
| add_tags | 添加标签 |
| add_labels | 添加键值对标签 |
| append | 追加值到字段 |
| drop_fields | 删除字段 |
| include_fields | 白名单保留字段 |
| drop_event | 丢弃整个事件 |
| add_id | 生成唯一 ID |

### 元数据注入类（11 个）

| 算子 | 许可 | 作用 |
|------|------|------|
| add_cloud_metadata | 开源 | 云平台元数据 |
| add_docker_metadata | 开源 | Docker 容器元数据 |
| add_kubernetes_metadata | 开源 | K8s 元数据 |
| add_host_metadata | 开源 | 主机信息 |
| add_process_metadata | 开源 | 进程元数据 |
| add_observer_metadata | 开源 | 观察者元数据 |
| add_locale | 开源 | 时区信息 |
| add_agent_metadata | 开源 | Agent 元数据 |
| add_cloudfoundry_metadata | X-Pack | Cloud Foundry 元数据 |
| add_nomad_metadata | X-Pack | Nomad 元数据 |
| add_session_metadata | X-Pack | 进程会话元数据 |

### 流控/脚本/网络类（6 个）

| 算子 | 作用 |
|------|------|
| script | 执行任意 JavaScript |
| rate_limit | 令牌桶限流 |
| dns | DNS 反查 |
| cache | 有状态缓存 |
| community_id | 网络流哈希 |
| add_network_direction | 网络方向判定 |

### 其他（6 个）

| 算子 | 作用 |
|------|------|
| fingerprint | 哈希指纹 |
| registered_domain | 提取注册域名 |
| translate_sid | Windows SID→用户名 |
| translate_ldap_attribute | LDAP 属性转换 |
| add_formatted_index | 格式化索引名 |
| now | 注入当前时间 |

---

## 附录 E：源码路径清单

### 核心接口与注册机制

```
D:\beats-main\beats-main\libbeat\beat\pipeline.go
D:\beats-main\beats-main\libbeat\processors\processor.go
D:\beats-main\beats-main\libbeat\processors\registry.go
D:\beats-main\beats-main\libbeat\processors\namespace.go
D:\beats-main\beats-main\libbeat\processors\config.go
D:\beats-main\beats-main\libbeat\processors\conditionals.go
D:\beats-main\beats-main\libbeat\processors\safe_processor.go
D:\beats-main\beats-main\libbeat\conditions\conditions.go
```

### 14 个解析解码类算子

```
D:\beats-main\beats-main\libbeat\processors\dissect\config.go
D:\beats-main\beats-main\libbeat\processors\dissect\processor.go
D:\beats-main\beats-main\libbeat\processors\dissect\dissect.go
D:\beats-main\beats-main\libbeat\processors\dissect\const.go
D:\beats-main\beats-main\libbeat\processors\dissect\delimiter.go
D:\beats-main\beats-main\libbeat\processors\dissect\field.go
D:\beats-main\beats-main\libbeat\processors\dissect\parser.go
D:\beats-main\beats-main\libbeat\processors\dissect\trim.go
D:\beats-main\beats-main\libbeat\processors\dissect\validate.go
D:\beats-main\beats-main\libbeat\processors\actions\decode_json_fields.go
D:\beats-main\beats-main\libbeat\processors\decode_csv_fields\decode_csv_fields.go
D:\beats-main\beats-main\libbeat\processors\decode_xml\decode_xml.go
D:\beats-main\beats-main\libbeat\processors\decode_xml\config.go
D:\beats-main\beats-main\libbeat\common\encoding\xml\decode.go
D:\beats-main\beats-main\libbeat\common\encoding\xml\safe_reader.go
D:\beats-main\beats-main\libbeat\processors\decode_xml_wineventlog\processor.go
D:\beats-main\beats-main\libbeat\processors\decode_xml_wineventlog\config.go
D:\beats-main\beats-main\libbeat\processors\decode_xml_wineventlog\decoder.go
D:\beats-main\beats-main\libbeat\processors\decode_xml_wineventlog\decoder_windows.go
D:\beats-main\beats-main\winlogbeat\sys\winevent\event.go
D:\beats-main\beats-main\winlogbeat\sys\winevent\winmeta.go
D:\beats-main\beats-main\libbeat\processors\syslog\syslog.go
D:\beats-main\beats-main\libbeat\reader\syslog\message.go
D:\beats-main\beats-main\libbeat\reader\syslog\syslog.go
D:\beats-main\beats-main\libbeat\reader\syslog\parser\rfc3164.rl
D:\beats-main\beats-main\libbeat\reader\syslog\parser\rfc5424.rl
D:\beats-main\beats-main\libbeat\reader\syslog\rfc3164_gen.go
D:\beats-main\beats-main\libbeat\reader\syslog\rfc5424_gen.go
D:\beats-main\beats-main\libbeat\processors\actions\decode_base64_field.go
D:\beats-main\beats-main\libbeat\processors\decode_duration\decode_duration.go
D:\beats-main\beats-main\libbeat\processors\urldecode\urldecode.go
D:\beats-main\beats-main\libbeat\processors\actions\decompress_gzip_field.go
D:\beats-main\beats-main\libbeat\processors\timestamp\timestamp.go
D:\beats-main\beats-main\libbeat\processors\timestamp\config.go
D:\beats-main\beats-main\libbeat\processors\actions\detect_mime_type.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\decode_cef.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\config.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\keys.ecs.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\cef.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\parser.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\keys.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\types.go
D:\beats-main\beats-main\x-pack\filebeat\processors\decode_cef\cef\option.go
D:\beats-main\beats-main\x-pack\filebeat\processors\aws_vpcflow\parse_aws_vpc_flow_log.go
D:\beats-main\beats-main\x-pack\filebeat\processors\aws_vpcflow\config.go
D:\beats-main\beats-main\x-pack\filebeat\processors\aws_vpcflow\mapping.go
D:\beats-main\beats-main\x-pack\filebeat\processors\aws_vpcflow\types.go
```

### Multiline 组件

```
D:\beats-main\beats-main\libbeat\reader\multiline\multiline.go
D:\beats-main\beats-main\libbeat\reader\multiline\multiline_config.go
D:\beats-main\beats-main\libbeat\reader\multiline\pattern.go
D:\beats-main\beats-main\libbeat\reader\multiline\counter.go
D:\beats-main\beats-main\libbeat\reader\multiline\while.go
D:\beats-main\beats-main\libbeat\reader\multiline\message_buffer.go
D:\beats-main\beats-main\libbeat\reader\parser\parser.go
```

### Pipeline 与执行链

```
D:\beats-main\beats-main\libbeat\publisher\pipeline\pipeline.go
D:\beats-main\beats-main\libbeat\publisher\pipeline\client.go
D:\beats-main\beats-main\libbeat\publisher\pipeline\consumer.go
D:\beats-main\beats-main\libbeat\publisher\pipeline\output_process.go
D:\beats-main\beats-main\libbeat\publisher\processing\default.go
D:\beats-main\beats-main\libbeat\publisher\processing\processing.go
D:\beats-main\beats-main\libbeat\publisher\processing\processors.go
```

### Input 相关

```
D:\beats-main\beats-main\filebeat\input\log\config.go
D:\beats-main\beats-main\filebeat\input\filestream\config.go
D:\beats-main\beats-main\filebeat\input\default-inputs\inputs.go
```

### 辅助工具

```
D:\beats-main\beats-main\libbeat\common\match\matcher.go
D:\beats-main\beats-main\libbeat\common\jsontransform\
D:\beats-main\beats-main\libbeat\common\encoding\xml\
```

---

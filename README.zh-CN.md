<div align="center">

# Open MES Korea

**小型、稳健且可扩展的开源 MES**

以韩国制造现场的真实业务流程为起点，
构建可扩展到不同国家、语言和行业的制造执行系统。

[한국어](README.md) · [English](README.en.md) · [日本語](README.ja.md)

</div>

> [!IMPORTANT]
> Open MES Korea 目前处于设计和早期实现阶段，尚不是可直接用于生产环境
> 的完整产品。API 和文档可能会在开发过程中发生变化。

![Open MES Korea - 从制造数据采集到分析](site/assets/open-mes-factory-team.jpg)

## 项目目标

Open MES Korea 不以替代完整 ERP 为目标，而是专注于：

```text
现场生产执行
  + LOT 批次追溯
  + 制造数据采集与分析
  + 受控 AI
```

项目以韩国制造业的术语、工作方式和实施条件作为现实起点，但 UI、文档、
业务术语和现场规则将采用支持多语言、多地区扩展的结构。默认语言为韩语。

## 把握数据采集黄金期

制造 AI 的第一步不是选择模型或分析厂商，而是在现场数据消失之前开始
采集。项目支持从人员录入、条码、CSV 和标准 API 开始，并通过
PostgreSQL、CSV 和 API 保存可迁移的数据。这样工厂可以在未来使用自身
历史数据比较 AI 模块和供应商，而不必在漫长选型后重新开始采集。

## 设计原则

- **小型核心：** 核心只包含通用制造执行流程
- **多语言：** 默认韩语，可扩展更多语言
- **可扩展：** 独立连接 ERP、设备、分析和行业规则
- **稳定：** 内置审计日志、幂等处理、修正历史和故障恢复
- **稳健：** 保证生产数据完整性和明确的 LOT genealogy
- **快速：** 重视现场录入和业务查询的响应速度
- **安全 AI：** 分离读取、建议、审批和执行权限

## 核心流程

```text
物料 / BOM / 工序
→ 工单
→ 工序开始与结束
→ 产量与不良记录
→ 原材料 LOT 投入
→ 产品 LOT 创建
→ 生产状态与 LOT 追溯
→ 基础分析与 AI 查询
```

## 核心功能

- 物料、BOM、工序、工艺路线、人员和设备
- 工单、工序实绩、产量和不良记录
- 原材料投入、产品 LOT 和 LOT genealogy
- 人工录入、条码、CSV 和经过认证的 HTTP ingestion
- 产量、不良率和工序时间的基础分析
- 用户、权限、审计日志和 event outbox

## 扩展功能

- ERP、WMS、QMS 和外部系统集成
- MQTT、OPC UA、Modbus、Serial 和 PLC connector
- 使用 Phoenix Broadway 进行高吞吐量事件采集
- 使用 TimescaleDB 或 ClickHouse 分析 telemetry
- OEE、高级排程、预测分析和行业仪表板
- AI 查询、建议和基于审批的操作

Broadway 不是分析引擎，它负责并发处理、背压、批处理、重试和故障隔离。

## 制造 AI 扩展模块

- 外观、尺寸、装配和 X-ray/CT 视觉检测
- 虚拟量测、数字孪生和虚拟调试
- 工艺参数、良率和能源优化
- AMR/AGV 路径优化与视觉拣选
- 需求、库存预测和 APS 排程
- 预测性维护与设备异常检测
- 防护用品、危险区域和危险行为检测
- 用于手册、作业标准和故障处理的制造 LLM

这些能力属于可选扩展模块，而不是核心内置功能。设备控制、质量判定和
人员安全相关决策必须经过现场验证、fail-safe、人类审批和审计记录。

## 项目状态

| 领域 | 状态 |
|---|---|
| 愿景与 MVP | 已完成文档 |
| 领域模型 | 初稿完成 |
| 系统与 AI 架构 | 初稿完成 |
| 应用脚手架 | 进行中 |
| MES Core | 早期实现 |
| LOT 追溯 | 计划中 |
| 数据采集与分析 | 计划中 |
| 多语言 UI | 计划中 |
| 生产版本 | 尚未发布 |

## 参与贡献

目前需要制造术语与异常流程审查、Elixir/Phoenix 和 PostgreSQL 开发、
现场平板 UX、LOT/质量/设备集成、多语言翻译，以及安全、性能和恢复测试。

贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

工厂技术负责人可以使用公开网站上的
[技术导入验证提示词](https://openmeskorea.org/#adoption-prompt)
与 LLM 一起评估准备度。

## 许可证

许可证尚未最终确定。目前优先考虑 MIT，并将在正式发布前添加
`LICENSE` 文件和版权声明。

---

<div align="center">

**Start small. Trace everything. Extend deliberately.**

</div>

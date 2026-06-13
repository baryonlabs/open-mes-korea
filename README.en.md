<div align="center">

# Open MES Korea

**A small, robust, and extensible open-source MES**

Built from real Korean manufacturing workflows and designed to extend across
countries, languages, and industries.

[한국어](README.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md)

[Vision](docs/vision.md) · [MVP](docs/mvp-scope.md) ·
[Architecture](docs/system-architecture.md) · [Roadmap](docs/roadmap.md) ·
[Contributing](CONTRIBUTING.md)

</div>

> [!IMPORTANT]
> Open MES Korea is currently in the design and early implementation stage.
> It is not yet a production-ready product, and its APIs and documentation may
> change during development.

![Open MES Korea - from manufacturing data collection to analysis](site/assets/open-mes-factory-team.jpg)

## Why Open MES Korea?

Manufacturing data is often scattered across work orders, paper reports,
spreadsheets, barcode systems, equipment, and ERP software. Even factories
with existing systems can struggle to connect process progress, defects, and
material-to-product lot history.

Open MES Korea does not aim to rebuild an entire ERP. It focuses on:

```text
Shop-floor execution
  + Lot traceability
  + Manufacturing data collection and analysis
  + Governed AI
```

Korean manufacturing terminology, practices, and deployment constraints are
the practical starting point. The architecture, however, is designed for
multilingual interfaces, regional terminology, and industry-specific
extensions.

## Preserve the Data Golden Time

The first step toward manufacturing AI is not selecting a model or analytics
vendor. It is collecting today's shop-floor data before it is lost.

Open MES Korea starts with operator input, barcodes, CSV, and standard
ingestion APIs. Data remains portable through PostgreSQL, CSV, and APIs, so a
factory can later compare AI modules and vendors using its own history instead
of restarting data collection after a long selection process.

## Design Goals

- **Small core:** Keep only common manufacturing execution workflows built in
- **Multilingual:** Korean by default, with support for more languages
- **Extensible:** Connect ERP, equipment, analytics, and industry rules
- **Reliable:** Audit logs, idempotency, correction history, and recovery
- **Robust:** Preserve production data integrity and explicit lot genealogy
- **Fast:** Keep shop-floor input and operational queries responsive
- **Operator-first:** Prioritize tablets, barcodes, and short input flows
- **Safe AI:** Separate reading, suggestions, approval, and execution

## Core Workflow

```text
Items / BOM / Processes
→ Work order
→ Operation start and completion
→ Production and defect records
→ Material lot consumption
→ Product lot creation
→ Production status and lot traceability
→ Basic analytics and AI queries
```

## Core and Extensions

### Core

- Master data, work orders, operations, production results, and defects
- Material consumption, product lots, and lot genealogy
- Manual input, barcode, CSV, and authenticated HTTP ingestion
- Production quantity, defect rate, and operation-time analytics
- Users, permissions, audit logs, and event outbox
- REST APIs, webhooks, and standard manufacturing events

### Extensions

- ERP, WMS, QMS, and external-system integrations
- MQTT, OPC UA, Modbus, serial, and PLC connectors
- High-throughput ingestion with Phoenix Broadway
- Telemetry analysis with TimescaleDB or ClickHouse
- OEE, advanced planning, predictive analytics, and industry dashboards
- Barcode and label templates and site-specific workflows
- AI queries, recommendations, and approval-based actions

Site-specific requirements should use explicit extension points instead of
continuously expanding the core.

## Manufacturing AI Modules

The extension roadmap goes beyond predictive maintenance:

- Vision inspection for surface, dimensional, assembly, and internal defects
- Virtual metrology and AI-assisted digital-twin commissioning
- Process-variable, yield, and energy optimization
- AMR/AGV routing and vision-guided robotic picking
- Demand, inventory, and APS scheduling optimization
- Predictive maintenance and equipment anomaly detection
- PPE, restricted-area, and hazardous-behavior detection
- Manufacturing LLMs for manuals, work instructions, and troubleshooting

These capabilities are optional modules, not built-in core features. Control,
quality disposition, and worker-safety decisions require explicit policies,
fail-safe behavior, site validation, human approval, and audit records.

## Data Collection and Analysis

The project aims to let factories collect and analyze their own operational
data without requiring a separate analytics platform first.

The default scope includes:

- Operator input, barcodes, CSV, and authenticated HTTP APIs
- Validation for malformed, duplicated, missing, or out-of-order data
- Structured work-order, operation, defect, and lot data
- Production quantity, defect-rate, and operation-time aggregation
- CSV export and APIs for external analytics

Broadway may be used as a high-throughput ingestion layer for equipment data.
It handles concurrency, back-pressure, batching, retries, and failure
isolation; it is not the analytics engine itself.

## Architecture

```text
Browser / Tablet
       │
       ▼
   Web / API ── MES Core ── PostgreSQL
       │
       ├── Background Jobs
       ├── Audit Log
       └── Event Outbox

PLC / Sensor / Equipment
       │
       ▼
 Edge Connector ── HTTP / MQTT ── Ingestion
                                      │
                         Broadway Extension (optional)
                                      │
                         Telemetry Store (optional)
```

Equipment events do not automatically become confirmed production results.
They are stored as candidates and matched against work orders, operations,
operators, and lots before confirmation.

## AI Principles

AI is not an autonomous production-data operator.

| Stage | Allowed behavior |
|---|---|
| Read | Query authorized production and lot context |
| Suggest | Propose anomalies, patterns, and checks |
| Approve | Let an authorized person review the proposal |
| Execute | Run only explicit approved actions with an audit record |

AI accesses data through a permission-aware Context API rather than querying
the database directly.

## Project Status

| Area | Status |
|---|---|
| Vision and MVP | Documented |
| Domain model | Draft complete |
| System and AI architecture | Draft complete |
| Manufacturer adoption guides | Draft complete |
| Application scaffolding | In progress |
| MES Core | Early implementation |
| Lot traceability | Planned |
| Data collection and analytics | Planned |
| Multilingual UI | Planned |
| Production release | Not released |

## Getting Started

There is no official runnable release yet. Start by reading:

1. [Vision](docs/vision.md)
2. [MVP Scope](docs/mvp-scope.md)
3. [Domain Model](docs/domain-model.md)
4. [System Architecture](docs/system-architecture.md)
5. [Contributing Guide](CONTRIBUTING.md)

Verified installation instructions and Docker Compose files will be added
after the first runnable scaffold is complete.

Factory technology owners can use the public
[AI adoption validation prompt](https://baryonlabs.github.io/open-mes-korea/#adoption-prompt)
with an LLM. The site also publishes
[`llms.txt`](https://baryonlabs.github.io/open-mes-korea/llms.txt).

## Roadmap

- [x] Phase 0: Vision, scope, and architecture
- [ ] Phase 1: MES Core
- [ ] Phase 2: Lot Traceability
- [ ] Phase 3: Shop-floor UX
- [ ] Phase 4: Data Collection and Basic Analytics
- [ ] Phase 5: AI Read-only and Decision Support
- [ ] Phase 6: Integrations and Extensions

## Contributing

The project currently needs:

- Reviews of manufacturing terminology and exception workflows
- Elixir/Phoenix and PostgreSQL implementation
- Shop-floor tablet UX
- Experience with lots, quality, equipment, and ERP integration
- Translation into English, Japanese, Chinese, and additional languages
- Testing of security, performance, and disaster recovery

Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing. Large features
should first be evaluated as either core behavior or an extension.

## Non-goals

- Replacing all ERP accounting, HR, purchasing, and sales functions
- Bundling every industry rule and PLC driver into the core
- Shipping advanced APS and full automation in the first release
- Allowing AI to modify production data without approval
- Presenting unimplemented features as production-ready

## License

The license has not been finalized. MIT is the leading candidate, and a
`LICENSE` file and copyright notice will be added before official distribution.

---

<div align="center">

**Start small. Trace everything. Extend deliberately.**

</div>

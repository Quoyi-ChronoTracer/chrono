# ChronoTracer Platform

Enterprise legal discovery and investigation timeline analysis platform.

## Components

| Directory | Repo | Stack |
|---|---|---|
| `chrono-app` | [chrono-app](https://github.com/Quoyi-ChronoTracer/chrono-app) | React 19 + TypeScript |
| `chrono-api` | [chrono-api](https://github.com/Quoyi-ChronoTracer/chrono-api) | Swift + AWS Lambda |
| `chrono-pipeline-v2` | [chrono-pipeline-v2](https://github.com/Quoyi-ChronoTracer/chrono-pipeline-v2) | Python |
| `chrono-filter-ai-api` | [chrono-filter-ai-api](https://github.com/Quoyi-ChronoTracer/chrono-filter-ai-api) | Python + FastAPI |
| `chrono-devops` | [chrono-devops](https://github.com/Quoyi-ChronoTracer/chrono-devops) | Docker + IaC |

## Setup

```bash
git clone --recurse-submodules https://github.com/Quoyi-ChronoTracer/chrono.git
cd chrono
```

See `CLAUDE.md` for engineering principles, branch conventions, submodule workflow, and AI tooling docs.

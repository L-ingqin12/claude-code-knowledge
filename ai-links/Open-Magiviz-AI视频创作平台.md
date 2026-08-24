---
title: Open-Magiviz — AI 视频创作平台
aliases: [Magiviz, ItusiAI-Open-Magiviz]
tags: [ai/links, ai/tools, reference]
created: 2026-08-18
updated: 2026-08-18
status: review
source_urls:
  - https://github.com/ItusiAI/Open-Magiviz
fetched_at: 2026-08-18
---

# Open-Magiviz — AI 视频创作平台

See also: [[AI-Links-KB-Home]] | [[2026-08-16-AI链接综述与归档]] | [[Articles-Index]] | [[AGENTS]]

> [!abstract] 定位
> [Open-Magiviz](https://github.com/ItusiAI/Open-Magiviz) 是开源 AI 视频创作 SaaS（magiviz.com 的公开源码）：从创意输入到成品视频的完整流水线，集成 Veo/Kling/Seedance/Wan 等多家视频生成模型，含用户系统、积分支付（Stripe）、版本管理与实时进度。技术栈：Next.js + TypeScript + Tailwind + Drizzle ORM + PostgreSQL + Stripe + Pusher + FAL AI。

## 一、核心工作流（五步串行 + 可中断可恢复）

```
创意输入 → ①AI剧情生成 → ②主角生成 → ③分镜图生成 → ④剧情视频生成 → ⑤完整视频合成
```

| 步骤 | 接口 | 要点 |
|---|---|---|
| ① 剧情 | `/api/ai/generate-story-details` | 结构化 JSON（标题/场景/角色/提示词）；LLM 非严格 JSON 兼容解析；按模型定分段时长（Veo 固定 8s、Seedance 4-30s 等） |
| ② 主角 | `/api/ai/generate-character-image` | 并行生成；支持参考图图生图；积分不足/解析失败独立分支 |
| ③ 分镜 | `/api/ai/generate-storyboard-image` | 并行；只传该场景引用角色的图片；**首尾帧模式**（首帧+尾帧同生，可单帧重生成） |
| ④ 视频 | `/api/ai/generate-story-video` | 并行；分镜图驱动；视频/音频多模态参考仅 Seedance 系支持；尾帧作为 additionalImageUrls |
| ⑤ 合成 | `/api/ai/fal/compose-story-video` | FAL AI 拼接：计算 keyframes（视频轨+音频轨）合并，输出总时长/缩略图/比例/大小 |

- **状态机**：`idle → script → character → storyboard → scenes → video`；暂停时先等待进行中 Pusher 任务（≤60s）再 abort；`resumeWorkflow` 按步骤分发恢复，不丢已有数据。
- **重生成语义**：单元素重生成会级联重跑下游（如重生成主角 → 受影响场景的分镜+视频+总视频）；每次重生成产生新 `versionGroupId` 实现双层版本控制（版本组 + 组内自增 version），历史不覆盖。

## 二、模型与参数

- 12 种视频模型：auto / veo31Lite / veo31Fast / veo31Quality / geminiOmni / seedance25 / seedance2 系 / kling3 / happyHorse / wan27 / minimaxH3。
- 参数面板：生成模式（普通/首尾帧）、比例（16:9/9:16）、时长（15s/30s/60s）、风格（auto/anime/hollywood/ads）。
- 上传视频/音频时自动锁定 Seedance 系并做媒体校验（数量/总时长/格式上限）。

## 三、商业系统

- **订阅计划 + 积分套餐**双轨：订阅用户积分消耗 67 折；积分按量购买；消费记录可查；推荐分销（邀请得积分）；管理员后台（用户管理/积分调整）；国际化 i18n。

## 四、技术栈与部署

- 前端：Next.js、TypeScript、Tailwind、shadcn/ui
- 后端：Next.js API Routes、Drizzle ORM、PostgreSQL
- 集成：Stripe（支付）、Pusher（实时推送）、FAL AI（视频合成）
- 部署：Vercel 一键（推荐）；环境变量含数据库、Stripe、AI 服务密钥（`# 安全特性` 声明敏感配置环境隔离）
- 注意：核心交互组件 `components/operate.tsx` 约 10,289 行（巨型组件，工程上可拆分的典型样本）

## 五、学习价值

- ★★★★☆ — 完整开源「AI 工作流 SaaS」参照：多模型编排、长流水线可中断/恢复/版本化、计费与实时进度推送，适合学习 AI 应用层产品化架构。
- 可借鉴点：五步流水线的状态机与级联重生成设计；双层版本管理（versionGroupId + version）；积分与订阅的商业化骨架。
- 注意点：巨型组件与内联 API 结构偏「小团队快跑」风格，生产级工程需重构分层。

## Related

- [[2026-08-16-AI链接综述与归档]] — 链接综述（本文作为追加条目 #17）
- [[AI-Links-KB-Home]] — 本子库 MOC
- [[Articles-Index]] — 文章库索引
- [[AGENTS]] — 知识库规范

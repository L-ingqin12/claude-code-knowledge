/**
 * fanout-service.ts — Fan-Out 多维度并行分析服务
 *
 * 核心模式: 将日志分析拆分为 4 个独立维度，每个维度使用独立 Agent 实例并行执行。
 *
 * ┌─────────────────────────────────────────────────┐
 * │                  analyzeLog()                     │
 * │                      │                           │
 * │         ┌────────────┼────────────┐              │
 * │         ▼            ▼            ▼              │
 * │   ┌──────────┐ ┌──────────┐ ┌──────────┐        │
 * │   │ ERROR    │ │ PERF     │ │ SECURITY │  ...   │
 * │   │ PATTERN  │ │ BOTTLENECK│ │ THREAT   │        │
 * │   │ Agent #1 │ │ Agent #2 │ │ Agent #3 │        │
 * │   └────┬─────┘ └────┬─────┘ └────┬─────┘        │
 * │        │            │            │               │
 * │        └────────────┼────────────┘               │
 * │                     ▼                            │
 * │              mergeResults()                      │
 * │          交叉验证 + 去重 + 排序                    │
 * │                     │                            │
 * │                     ▼                            │
 * │              统一分析结果                          │
 * └─────────────────────────────────────────────────┘
 *
 * 与 LLM 自主 Fan-Out 的对比:
 *   代码级 Fan-Out (本模块): 固定 4 维度, Promise.all 并行, 可控性强
 *   LLM 自主 Fan-Out:         LLM 决定并行哪些工具, 更灵活但不可控
 *
 * 防冲突原则 (来自 [[fan-out-subagent-pattern]]):
 *   - 各维度只读分析 → 可以任意并行
 *   - 汇总阶段交叉验证 → 同一问题被多维度发现 → 提升置信度
 *   - 无写操作 → 无冲突风险
 *
 * 参考:
 *   - [[fan-out-subagent-pattern]] — Fan-Out 设计模式
 *   - [[opencode-multi-agent-architecture]] — Primary/Subagent 两层模型
 */

import { createLogAnalysisAgent } from "./agent-service.js";
import type { AnalysisResult, AnalysisIssue } from "./analysis/result-parser.js";

// ============================================================
// 类型定义
// ============================================================

/** 分析维度 */
export type AnalysisDimension = "ERROR_PATTERN" | "PERFORMANCE" | "SECURITY" | "ANOMALY";

export interface FanoutOptions {
  logContent: string;
  context?: {
    source?: string;
    format?: string;
    hint?: string;
    timeout?: number;
  };
  /** 启用哪些维度 (默认全部) */
  dimensions?: AnalysisDimension[];
  /** 进度回调 (每个维度) */
  onProgress?: (dimension: AnalysisDimension, event: { type: string; data: string }) => void;
}

export interface DimensionResult {
  dimension: AnalysisDimension;
  analysis: AnalysisResult;
  elapsedMs: number;
  agentTurns: number;
}

export interface FanoutResult {
  merged: AnalysisResult;
  dimensionResults: DimensionResult[];
  totalElapsedMs: number;
}

// ============================================================
// 维度定义
// ============================================================

interface DimensionConfig {
  name: AnalysisDimension;
  label: string;
  systemPrompt: string;
  searchKeywords: string[];
}

const DIMENSIONS: DimensionConfig[] = [
  {
    name: "ERROR_PATTERN",
    label: "错误模式识别",
    systemPrompt: `
You are an error pattern analyst. Focus ONLY on errors.
Identify: error types, root causes, cascading failures, frequency patterns.
Search for: error, fatal, panic, exception, crash, fail, abort, refused.
For each error found: classify by type, count occurrences, identify first/last time.
Output STRICT JSON with dimension="ERROR_PATTERN".
`.trim(),
    searchKeywords: ["error", "fatal", "panic", "exception", "crash", "fail", "abort", "refused"],
  },
  {
    name: "PERFORMANCE",
    label: "性能瓶颈分析",
    systemPrompt: `
You are a performance analyst. Focus ONLY on performance issues.
Identify: slow operations, timeouts, resource bottlenecks, latency spikes.
Search for: timeout, slow, duration, latency, ms, queue, wait, throttle.
Calculate: P50/P95/P99 where timestamp data is available.
Output STRICT JSON with dimension="PERFORMANCE".
`.trim(),
    searchKeywords: ["timeout", "slow", "duration", "latency", "ms", "queue", "wait", "throttle", "delay"],
  },
  {
    name: "SECURITY",
    label: "安全威胁检测",
    systemPrompt: `
You are a security analyst. Focus ONLY on security threats.
Identify: unauthorized access, injection attempts, brute force, data exfiltration, privilege escalation.
Search for: unauthorized, forbidden, injection, bypass, exploit, brute, suspicious.
Flag: high-frequency failed auth, unusual IPs, path traversal, SQL injection patterns.
Even if uncertain, flag suspicious patterns with "confidence": <low>.
Output STRICT JSON with dimension="SECURITY".
`.trim(),
    searchKeywords: ["unauthorized", "forbidden", "injection", "bypass", "exploit", "brute", "suspicious", "auth", "permission denied"],
  },
  {
    name: "ANOMALY",
    label: "时序异常检测",
    systemPrompt: `
You are an anomaly detection analyst. Focus ONLY on timing anomalies.
Identify: error storms, gradual degradation, periodic patterns, outlier events.
Search for: sudden spikes, gaps in logging, pattern repetition, unusual quiet periods.
Compare: different time windows, different services/components.
Output STRICT JSON with dimension="ANOMALY".
`.trim(),
    searchKeywords: ["spike", "burst", "gap", "pattern", "sudden", "unusual", "peak", "drop", "silence"],
  },
];

// ============================================================
// Fan-Out 主函数
// ============================================================

/**
 * Fan-Out 多维度并行分析
 *
 * 流程:
 *   1. 为每个维度创建独立 Agent 实例
 *   2. Promise.all 并行执行所有维度
 *   3. 汇总 + 交叉验证 + 去重
 *   4. 返回统一结果
 */
export async function fanoutAnalyze(options: FanoutOptions): Promise<FanoutResult> {
  const { logContent, context, onProgress } = options;
  const dimensions = options.dimensions || DIMENSIONS.map((d) => d.name);

  const startTime = Date.now();

  console.log(`[FanOut] 启动 ${dimensions.length} 个维度并行分析`);

  // ── Fan-Out: 并行创建并执行所有维度 ──
  const dimensionPromises = DIMENSIONS
    .filter((d) => dimensions.includes(d.name))
    .map(async (dimConfig): Promise<DimensionResult> => {
      const dimStart = Date.now();

      try {
        onProgress?.(dimConfig.name, { type: "start", data: dimConfig.label });

        const session = await createLogAnalysisAgent();

        let turnsUsed = 0;
        session.subscribe((event) => {
          if (event.type === "turn_end") turnsUsed++;
          if (event.type === "tool_execution_start") {
            onProgress?.(dimConfig.name, {
              type: "tool",
              data: event.toolCall.name,
            });
          }
        });

        // ── 构建维度专用分析 prompt ──
        const prompt = buildDimensionPrompt(dimConfig, logContent, context);

        // 超时控制 (使用维度超时，取上下文中超时的一半)
        const dimTimeout = (context?.timeout || 60) * 1000 * 0.75;

        await Promise.race([
          session.prompt(prompt),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error("DIMENSION_TIMEOUT")), dimTimeout)
          ),
        ]);

        // 提取结果
        const lastMessage = session.agent.state.messages.at(-1);
        const { parseAnalysisResult } = await import("./analysis/result-parser.js");
        const analysis = parseAnalysisResult(lastMessage);

        await session.dispose();

        const elapsed = Date.now() - dimStart;
        onProgress?.(dimConfig.name, {
          type: "done",
          data: `${analysis.issues.length} issues, confidence=${analysis.confidence}`,
        });

        console.log(
          `[FanOut] ${dimConfig.name}: ${analysis.issues.length} issues, ` +
          `${elapsed}ms, ${turnsUsed} turns`
        );

        return {
          dimension: dimConfig.name,
          analysis,
          elapsedMs: elapsed,
          agentTurns: turnsUsed,
        };

      } catch (err) {
        console.error(`[FanOut] ${dimConfig.name} 失败:`, err);
        return {
          dimension: dimConfig.name,
          analysis: {
            summary: `${dimConfig.label} 分析失败: ${(err as Error).message}`,
            severity: "warn",
            issues: [],
            stats: { total_lines: 0, error_lines: 0, warning_lines: 0, time_range: { start: null, end: null } },
            confidence: 0,
            turnsUsed: 0,
          },
          elapsedMs: Date.now() - dimStart,
          agentTurns: 0,
        };
      }
    });

  // ── Fan-In: 等待所有维度完成 ──
  const dimensionResults = await Promise.all(dimensionPromises);

  // ── Merge: 交叉验证 + 去重 + 排序 ──
  const merged = mergeResults(dimensionResults, logContent);

  const totalElapsed = Date.now() - startTime;

  console.log(
    `[FanOut] 全部完成: ${dimensionResults.length} 维度, ` +
    `${merged.issues.length} 去重后 issues, ${totalElapsed}ms`
  );

  return {
    merged,
    dimensionResults,
    totalElapsedMs: totalElapsed,
  };
}

// ============================================================
// Prompt 构建
// ============================================================

function buildDimensionPrompt(
  dimConfig: DimensionConfig,
  logContent: string,
  context?: FanoutOptions["context"]
): string {
  const parts: string[] = [];

  parts.push(dimConfig.systemPrompt);
  parts.push("");

  if (context?.source) {
    parts.push(`Source: ${context.source}`);
  }
  if (context?.hint) {
    parts.push(`Hint: ${context.hint}`);
  }

  parts.push(`Keywords to search: ${dimConfig.searchKeywords.join(", ")}`);
  parts.push("");
  parts.push("Analyze the following log. Output STRICT JSON ONLY (no markdown, no extra text).");
  parts.push("If no issues found in your dimension, return empty issues array. DO NOT fabricate.");
  parts.push("");

  // 截断过大日志
  const maxChars = 50000;
  const truncated = logContent.length > maxChars;
  const logSnippet = logContent.slice(0, maxChars);

  parts.push("```");
  parts.push(logSnippet);
  parts.push("```");

  if (truncated) {
    parts.push(`(Log truncated: ${logContent.length} → ${maxChars} chars)`);
  }

  return parts.join("\n");
}

// ============================================================
// 结果合并 — 交叉验证 + 去重
// ============================================================

function mergeResults(
  dimensionResults: DimensionResult[],
  _originalLog: string
): AnalysisResult {
  const allIssues: (AnalysisIssue & { _dimensions: string[]; _maxConfidence: number })[] = [];

  // ── 收集所有 issues ──
  for (const dr of dimensionResults) {
    for (const issue of dr.analysis.issues) {
      allIssues.push({
        ...issue,
        _dimensions: [dr.dimension],
        _maxConfidence: dr.analysis.confidence,
      });
    }
  }

  // ── 去重 + 交叉验证 ──
  // 如果两个 issue 描述的是同一行/同一模式 → 合并，提升置信度
  const merged = new Map<string, AnalysisIssue & { cross_validated_by: string[]; aggregated_confidence: number }>();

  for (const issue of allIssues) {
    // 去重键: 行号 + evidence hash
    const dedupKey = `${issue.line || "noline"}-${hashString(issue.evidence.slice(0, 80))}`;

    if (merged.has(dedupKey)) {
      // 交叉验证: 同一问题被多个维度发现 → 提升
      const existing = merged.get(dedupKey)!;
      existing.cross_validated_by.push(issue._dimensions[0]);
      existing.aggregated_confidence = Math.min(
        1.0,
        existing.aggregated_confidence + 0.15 // 每个交叉验证 +0.15
      );
      // 取更严重的 severity
      if (severityRank(issue.severity) > severityRank(existing.severity)) {
        existing.severity = issue.severity;
      }
    } else {
      merged.set(dedupKey, {
        ...issue,
        cross_validated_by: [...issue._dimensions],
        aggregated_confidence: issue._maxConfidence,
      });
    }
  }

  // ── 汇总统计 ──
  const issues = Array.from(merged.values())
    .map(({ _dimensions, _maxConfidence, cross_validated_by, aggregated_confidence, ...rest }) => ({
      ...rest,
      // 如果被多个维度交叉验证，在 evidence 中标注
      evidence: cross_validated_by.length > 1
        ? `[交叉验证: ${cross_validated_by.join(", ")}] ${rest.evidence}`
        : rest.evidence,
    }))
    .sort((a, b) => severityRank(b.severity) - severityRank(a.severity));

  // 综合 confidence
  const avgConfidence = dimensionResults.length > 0
    ? dimensionResults.reduce((sum, d) => sum + d.analysis.confidence, 0) / dimensionResults.length
    : 0;

  // 综合 severity: 取最严重的
  const allSeverities = issues.map((i) => i.severity);
  const overallSeverity = allSeverities.includes("critical") ? "critical"
    : allSeverities.includes("error") ? "error"
    : allSeverities.includes("warn") ? "warn"
    : "info";

  // 汇总 stats
  const stats = dimensionResults.reduce(
    (acc, d) => ({
      total_lines: Math.max(acc.total_lines, d.analysis.stats.total_lines),
      error_lines: acc.error_lines + d.analysis.stats.error_lines,
      warning_lines: acc.warning_lines + d.analysis.stats.warning_lines,
      time_range: {
        start: acc.time_range.start || d.analysis.stats.time_range.start,
        end: acc.time_range.end || d.analysis.stats.time_range.end,
      },
    }),
    { total_lines: 0, error_lines: 0, warning_lines: 0, time_range: { start: null as string | null, end: null as string | null } }
  );

  return {
    summary: [
      `Fan-Out 多维度分析完成 (${dimensionResults.length} 维度)`,
      `发现 ${issues.length} 个问题`,
      issues.length > 0
        ? `最严重: ${issues[0].severity} — ${issues[0].title}`
        : "未发现问题",
    ].join(" | "),
    severity: overallSeverity,
    issues: issues.slice(0, 50), // 最多 50 个 issues
    stats,
    confidence: Math.round(avgConfidence * 100) / 100,
    turnsUsed: 0,
  };
}

// ============================================================
// 辅助
// ============================================================

function severityRank(s: string): number {
  switch (s) {
    case "critical": return 4;
    case "error": return 3;
    case "warn": return 2;
    case "info": return 1;
    default: return 0;
  }
}

function hashString(s: string): string {
  let hash = 0;
  for (let i = 0; i < s.length; i++) {
    const chr = s.charCodeAt(i);
    hash = ((hash << 5) - hash) + chr;
    hash |= 0;
  }
  return Math.abs(hash).toString(36);
}

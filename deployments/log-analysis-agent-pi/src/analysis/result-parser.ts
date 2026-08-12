/**
 * result-parser.ts — 分析结果解析
 *
 * 从 Agent 最终消息中提取结构化 JSON 结果。
 * 处理 LLM 输出中的常见格式问题:
 *   - JSON 被 markdown 代码块包裹
 *   - 尾部逗号
 *   - 不完整的 JSON (截断)
 */

// ============================================================
// 类型定义
// ============================================================

export interface AnalysisIssue {
  id: string;
  dimension: "ERROR_PATTERN" | "PERFORMANCE" | "SECURITY" | "ANOMALY";
  severity: "critical" | "error" | "warn" | "info";
  title: string;
  description: string;
  evidence: string;
  line: number | null;
  count: number;
  recommendation: string;
}

export interface AnalysisStats {
  total_lines: number;
  error_lines: number;
  warning_lines: number;
  time_range: {
    start: string | null;
    end: string | null;
  };
}

export interface AnalysisResult {
  summary: string;
  severity: "critical" | "error" | "warn" | "info";
  issues: AnalysisIssue[];
  stats: AnalysisStats;
  confidence: number;
  note?: string;
  truncated?: boolean;
  error?: string;
  rawOutput?: string;
  turnsUsed: number;
}

// ============================================================
// 解析函数
// ============================================================

/**
 * 从 Agent 最后一条消息中提取分析结果
 */
export function parseAnalysisResult(
  lastMessage: any
): AnalysisResult {
  // 默认空结果
  const emptyResult: AnalysisResult = {
    summary: "分析失败: 无法解析 Agent 输出",
    severity: "error",
    issues: [],
    stats: { total_lines: 0, error_lines: 0, warning_lines: 0, time_range: { start: null, end: null } },
    confidence: 0,
    turnsUsed: 0,
  };

  if (!lastMessage) {
    return { ...emptyResult, error: "no_agent_output" };
  }

  // 提取文本内容
  let text = "";
  if (typeof lastMessage === "string") {
    text = lastMessage;
  } else if (lastMessage.content) {
    if (typeof lastMessage.content === "string") {
      text = lastMessage.content;
    } else if (Array.isArray(lastMessage.content)) {
      text = lastMessage.content
        .filter((c: any) => c.type === "text")
        .map((c: any) => c.text)
        .join("\n");
    }
  }

  if (!text.trim()) {
    return { ...emptyResult, error: "empty_agent_output", rawOutput: text };
  }

  // ── 提取 JSON ──
  const json = extractJson(text);
  if (!json) {
    return {
      ...emptyResult,
      error: "json_extraction_failed",
      rawOutput: text.slice(0, 500),
    };
  }

  // ── 解析并填充默认值 ──
  try {
    const parsed = JSON.parse(json);

    return {
      summary: parsed.summary || "分析完成 (无总结)",
      severity: validateSeverity(parsed.severity),
      issues: (parsed.issues || []).map(normalizeIssue),
      stats: normalizeStats(parsed.stats),
      confidence: clampConfidence(parsed.confidence),
      note: parsed.note,
      truncated: parsed.truncated || false,
      turnsUsed: 0,
    };
  } catch (err) {
    return {
      ...emptyResult,
      error: `json_parse_error: ${(err as Error).message}`,
      rawOutput: json.slice(0, 500),
    };
  }
}

// ============================================================
// 辅助函数
// ============================================================

/**
 * 从 LLM 输出中提取 JSON
 * 处理常见格式:
 *   ```json {...} ```
 *   ``` {...} ```
 *   裸 JSON
 */
function extractJson(text: string): string | null {
  // 尝试匹配 ```json ... ``` 代码块
  const blockMatch = text.match(/```(?:json)?\s*\n?([\s\S]*?)\n?```/);
  if (blockMatch) {
    return blockMatch[1].trim();
  }

  // 尝试匹配裸 JSON 对象
  const braceStart = text.indexOf("{");
  if (braceStart === -1) return null;

  // 从第一个 { 开始，找到匹配的 }
  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let i = braceStart; i < text.length; i++) {
    const ch = text[i];

    if (escaped) {
      escaped = false;
      continue;
    }

    if (ch === "\\") {
      escaped = true;
      continue;
    }

    if (ch === '"') {
      inString = !inString;
      continue;
    }

    if (!inString) {
      if (ch === "{") depth++;
      if (ch === "}") {
        depth--;
        if (depth === 0) {
          return text.slice(braceStart, i + 1);
        }
      }
    }
  }

  return null;
}

function validateSeverity(s: any): AnalysisResult["severity"] {
  const valid = ["critical", "error", "warn", "info"];
  return valid.includes(s) ? s : "warn";
}

function normalizeIssue(raw: any): AnalysisIssue {
  return {
    id: raw.id || `ISSUE-${Math.random().toString(36).slice(2, 6).toUpperCase()}`,
    dimension: ["ERROR_PATTERN", "PERFORMANCE", "SECURITY", "ANOMALY"].includes(raw.dimension)
      ? raw.dimension : "ERROR_PATTERN",
    severity: ["critical", "error", "warn", "info"].includes(raw.severity)
      ? raw.severity : "warn",
    title: raw.title || "未命名问题",
    description: raw.description || "",
    evidence: raw.evidence || "",
    line: typeof raw.line === "number" ? raw.line : null,
    count: typeof raw.count === "number" ? raw.count : 1,
    recommendation: raw.recommendation || "",
  };
}

function normalizeStats(raw: any): AnalysisStats {
  return {
    total_lines: typeof raw?.total_lines === "number" ? raw.total_lines : 0,
    error_lines: typeof raw?.error_lines === "number" ? raw.error_lines : 0,
    warning_lines: typeof raw?.warning_lines === "number" ? raw.warning_lines : 0,
    time_range: {
      start: raw?.time_range?.start || null,
      end: raw?.time_range?.end || null,
    },
  };
}

function clampConfidence(c: any): number {
  if (typeof c !== "number") return 0.5;
  return Math.max(0, Math.min(1, c));
}

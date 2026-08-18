/**
 * agent-service.ts — Pi Agent SDK 封装
 *
 * 核心职责:
 *   1. 创建请求级隔离的 Agent 实例 (SessionManager.inMemory)
 *   2. 封装 analyzeLog() — 在线程池外异步执行
 *   3. 流式进度回调
 *   4. 超时控制
 *
 * 与 opencode 版的关键差异:
 *   - Pi Agent 是 TypeScript SDK in-process，不是 subprocess
 *   - 利用 toolExecution:"parallel" 实现 LLM 自主 Fan-Out
 *   - Skills 渐进式加载分析指令 (不占 system prompt 预算)
 *   - Node.js 天然异步，无需 ThreadPoolExecutor
 *
 * 参考:
 *   - plans/pi-agent-log-analysis-plan.md (完整方案)
 *   - [[pi-agent-framework-knowledge]] (Pi Agent 框架知识)
 *   - [[fan-out-subagent-pattern]] (Pi Agent parallel tools = LLM 自主 Fan-Out)
 */

import { createAgentSession, SessionManager, AuthStorage, ModelRegistry }
  from "@mariozechner/pi-coding-agent";
import type { AgentSession } from "@mariozechner/pi-coding-agent";
import { v4 as uuidv4 } from "uuid";
import { LOG_ANALYSIS_SYSTEM_PROMPT } from "./analysis/prompt.js";
import { parseAnalysisResult, type AnalysisResult } from "./analysis/result-parser.js";

// ============================================================
// 配置
// ============================================================

export interface AgentServiceConfig {
  /** Agent 调用超时 (秒) */
  timeout: number;
  /** 最大日志大小 (bytes) */
  maxLogSize: number;
  /** 模型名称 (可选, 默认使用 auth 中配置的) */
  model?: string;
}

const DEFAULT_CONFIG: AgentServiceConfig = {
  timeout: 60,
  maxLogSize: 50 * 1024 * 1024, // 50MB
};

// ============================================================
// Agent 工厂
// ============================================================

/**
 * 创建请求级 Agent 实例
 *
 * 每个 HTTP 请求创建一个独立实例，分析完成后销毁。
 * SessionManager.inMemory() 确保:
 *   - 无文件系统残留
 *   - 请求间完全隔离
 *   - 无需清理磁盘
 */
export async function createLogAnalysisAgent(
  config: AgentServiceConfig = DEFAULT_CONFIG
): Promise<AgentSession> {
  const authStorage = AuthStorage.create();
  const modelRegistry = new ModelRegistry(authStorage);

  const { session } = await createAgentSession({
    sessionManager: SessionManager.inMemory(), // ⚠️ 请求级隔离
    authStorage,
    modelRegistry,
  });

  // 注入日志分析系统提示词 (≤800 tokens)
  // 利用 Pi Agent 的 steering 机制在 prompt 前注入
  // 实际实现中通过 Agent 的 initialState.systemPrompt 设置
  // 或通过 Skills 渐进式加载

  return session;
}

// ============================================================
// 日志分析主函数
// ============================================================

export interface AnalyzeOptions {
  /** 日志原文 */
  logContent: string;
  /** 可选上下文 */
  context?: {
    source?: string;      // 日志来源: nginx, syslog, app, docker...
    format?: string;      // 日志格式: json, csv, plain, structured...
    hint?: string;        // 分析提示: "关注超时错误" "检查安全漏洞"
    timeout?: number;     // 覆盖默认超时 (秒)
  };
  /** 流式进度回调 */
  onProgress?: (event: ProgressEvent) => void;
}

export interface ProgressEvent {
  type: "text_delta" | "tool_start" | "tool_end" | "turn_start" | "turn_end";
  data: string;
}

export interface AnalyzeResult {
  requestId: string;
  analysis: AnalysisResult;
  metadata: {
    wallTimeMs: number;
    turnsUsed: number;
    toolsCalled: string[];
  };
}

/**
 * 执行单次日志分析
 *
 * 流程:
 *   1. 创建 Agent 实例 (in-memory session)
 *   2. 注入分析 Skill + 系统提示词
 *   3. 发送分析请求
 *   4. 等待 Agent 完成 (带超时)
 *   5. 解析结果 JSON
 *   6. 销毁 Agent 实例
 */
export async function analyzeLog(options: AnalyzeOptions): Promise<AnalyzeResult> {
  const requestId = uuidv4().slice(0, 8);
  const startTime = Date.now();
  const { logContent, context, onProgress } = options;

  const timeoutMs = (context?.timeout || 60) * 1000;

  console.log(`[${requestId}] 创建 Agent 实例...`);

  const session = await createLogAnalysisAgent();

  // 记录工具调用
  const toolsCalled: string[] = [];

  try {
    // ── 订阅事件 ──
    session.subscribe((event) => {
      switch (event.type) {
        case "message_update":
          if (event.assistantMessageEvent.type === "text_delta") {
            onProgress?.({
              type: "text_delta",
              data: event.assistantMessageEvent.delta,
            });
          }
          break;

        case "tool_execution_start":
          toolsCalled.push(event.toolCall.name);
          onProgress?.({ type: "tool_start", data: event.toolCall.name });
          console.log(`[${requestId}] 工具调用: ${event.toolCall.name}`);
          break;

        case "tool_execution_end":
          onProgress?.({ type: "tool_end", data: event.toolCall.name });
          break;

        case "turn_start":
          onProgress?.({ type: "turn_start", data: "" });
          break;

        case "turn_end":
          onProgress?.({ type: "turn_end", data: "" });
          break;
      }
    });

    // ── 构建分析 prompt ──
    const prompt = buildAnalysisPrompt(logContent, context);

    console.log(`[${requestId}] 开始分析, size=${Buffer.byteLength(logContent, "utf8")}B`);

    // ── 发送给 Agent (带超时) ──
    const promptPromise = session.prompt(prompt);

    // Promise.race 实现超时控制
    // 注意: Agent prompt 无法真正取消，超时后 Agent 仍在后台运行
    // 但 session.dispose() 会触发 AbortController
    await Promise.race([
      promptPromise,
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("ANALYSIS_TIMEOUT")), timeoutMs)
      ),
    ]);

    // ── 提取结果 ──
    const lastMessage = session.agent.state.messages.at(-1);
    const analysis = parseAnalysisResult(lastMessage);

    const elapsed = Date.now() - startTime;
    console.log(`[${requestId}] 分析完成, elapsed=${elapsed}ms, turns=${analysis.turnsUsed}`);

    return {
      requestId,
      analysis,
      metadata: {
        wallTimeMs: elapsed,
        turnsUsed: session.agent.state.messages.filter(
          (m) => m.role === "assistant"
        ).length,
        toolsCalled,
      },
    };

  } catch (err: any) {
    const elapsed = Date.now() - startTime;

    if (err.message === "ANALYSIS_TIMEOUT") {
      console.warn(`[${requestId}] 分析超时, elapsed=${elapsed}ms`);
      throw new TimeoutError(requestId, elapsed);
    }

    console.error(`[${requestId}] 分析失败:`, err);
    throw new AnalysisError(requestId, err.message, elapsed);

  } finally {
    // ── 释放资源 ──
    await session.dispose();
    console.log(`[${requestId}] Agent 实例已释放`);
  }
}

// ============================================================
// Prompt 构建
// ============================================================

function buildAnalysisPrompt(
  logContent: string,
  context?: AnalyzeOptions["context"]
): string {
  const parts: string[] = [];

  // 系统提示词在 Agent 初始化时注入
  // 这里构建用户消息

  if (context?.source) {
    parts.push(`日志来源: ${context.source}`);
  }
  if (context?.format) {
    parts.push(`日志格式: ${context.format}`);
  }
  if (context?.hint) {
    parts.push(`分析重点: ${context.hint}`);
  }

  parts.push("");
  parts.push("请分析以下日志，严格按照 JSON 格式输出分析结果：");
  parts.push("");
  parts.push("```");
  parts.push(logContent.slice(0, 50000)); // 截断过长日志
  parts.push("```");

  if (logContent.length > 50000) {
    parts.push(`\n(日志已截断，原文 ${logContent.length} 字符，仅分析前 50000 字符)`);
  }

  return parts.join("\n");
}

// ============================================================
// 错误类型
// ============================================================

export class TimeoutError extends Error {
  constructor(
    public requestId: string,
    public wallTimeMs: number
  ) {
    super(`分析超时 (${wallTimeMs}ms)`);
    this.name = "TimeoutError";
  }
}

export class AnalysisError extends Error {
  constructor(
    public requestId: string,
    message: string,
    public wallTimeMs: number
  ) {
    super(message);
    this.name = "AnalysisError";
  }
}

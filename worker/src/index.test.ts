import { describe, it, expect, vi, beforeEach } from "vitest";
import { shortenWithLLM, stripMarkdown, hasNegativePolarity, type Env } from "./index";

function mockEnv(): Env {
  return {
    ANTHROPIC_API_KEY: "test-key",
    REQUESTS: {} as KVNamespace,
    APNS_PRIVATE_KEY: "",
    APNS_KEY_ID: "",
    APNS_TEAM_ID: "",
    APNS_BUNDLE_ID: "",
    SHARED_SECRET: "",
    APNS_USE_SANDBOX: "true",
  };
}

function mockFetch(response: string | null, status = 200) {
  return vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    json: () => Promise.resolve(response !== null ? { content: [{ type: "text", text: response }] } : {}),
  });
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("shortenWithLLM", () => {
  it("translates and shortens into Japanese under maxChars", async () => {
    globalThis.fetch = mockFetch("認証ミドルウェアのリファクタリング完了、テスト全通過");
    const result = await shortenWithLLM(
      mockEnv(),
      "Claude Code has completed the requested refactoring of the auth middleware, all tests passing",
      100,
    );
    expect(result).toBe("認証ミドルウェアのリファクタリング完了、テスト全通過");
  });

  it("returns original text on HTTP error", async () => {
    globalThis.fetch = mockFetch(null, 500);
    const original = "Some long message that the API will fail to shorten";
    const result = await shortenWithLLM(mockEnv(), original, 100);
    expect(result).toBe(original);
  });

  it("returns original text on network failure", async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error("Network error"));
    const original = "Another long message";
    const result = await shortenWithLLM(mockEnv(), original, 100);
    expect(result).toBe(original);
  });

  it("returns original text when response is empty", async () => {
    globalThis.fetch = mockFetch("");
    const original = "A message that must not be lost";
    const result = await shortenWithLLM(mockEnv(), original, 100);
    expect(result).toBe(original);
  });

  it("returns original text when response content is missing", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.resolve({}),
    });
    const original = "Important notification content";
    const result = await shortenWithLLM(mockEnv(), original, 100);
    expect(result).toBe(original);
  });

  it("caps output at maxChars", async () => {
    globalThis.fetch = mockFetch("あ".repeat(200));
    const result = await shortenWithLLM(mockEnv(), "original long text", 100);
    expect(result.length).toBeLessThanOrEqual(100);
  });

  it("strips markdown from LLM output", async () => {
    globalThis.fetch = mockFetch("**ビルド成功** ✅\n\n- テスト全通過\n- `lint` OK");
    const result = await shortenWithLLM(mockEnv(), "long message", 100);
    expect(result).not.toMatch(/[*`#|>~]/);
    expect(result).toContain("ビルド成功");
    expect(result).toContain("✅");
  });

  it("strips markdown in fallback path on error", async () => {
    globalThis.fetch = mockFetch(null, 500);
    const result = await shortenWithLLM(mockEnv(), "**bold** message", 100);
    expect(result).toBe("bold message");
  });

  it("preserves plain text in fallback path", async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error("network"));
    const plain = "Build succeeded after 42 seconds with zero warnings";
    const result = await shortenWithLLM(mockEnv(), plain, 100);
    expect(result).toBe(plain);
  });

  it("recovers from Anthropic error-shaped 200 response", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      headers: { get: () => "req-123" },
      json: () => Promise.resolve({ type: "error", error: { type: "overloaded_error" } }),
    });
    const result = await shortenWithLLM(mockEnv(), "Plain fallback text here", 100);
    expect(result).toBe("Plain fallback text here");
  });

  it("falls back to original when stripped LLM output is empty", async () => {
    globalThis.fetch = mockFetch("```\nonly fenced code\n```");
    const result = await shortenWithLLM(mockEnv(), "Original message survives", 100);
    expect(result).toBe("Original message survives");
  });

  it("falls back to original when LLM drops negative polarity (input negative → output positive)", async () => {
    globalThis.fetch = mockFetch("✅ビルド完了");
    const input = "Tests failed: 3 of 12 cases broken";
    const result = await shortenWithLLM(mockEnv(), input, 100);
    expect(result).toBe(input);
  });

  it("allows positive input → positive output (no false fallback)", async () => {
    globalThis.fetch = mockFetch("ビルド完了");
    const result = await shortenWithLLM(mockEnv(), "Build succeeded after 42 seconds", 100);
    expect(result).toBe("ビルド完了");
  });

  it("allows negative input → negative output (polarity preserved)", async () => {
    globalThis.fetch = mockFetch("❌テスト失敗");
    const result = await shortenWithLLM(mockEnv(), "Tests failed: 3 broken", 100);
    expect(result).toBe("❌テスト失敗");
  });
});

describe("hasNegativePolarity", () => {
  it("detects Japanese failure tokens", () => {
    expect(hasNegativePolarity("テスト失敗")).toBe(true);
    expect(hasNegativePolarity("エラー発生")).toBe(true);
    expect(hasNegativePolarity("リクエスト拒否")).toBe(true);
    expect(hasNegativePolarity("ビルド中断")).toBe(true);
    expect(hasNegativePolarity("警告3件")).toBe(true);
  });

  it("detects English failure tokens", () => {
    expect(hasNegativePolarity("Tests failed")).toBe(true);
    expect(hasNegativePolarity("Build failure")).toBe(true);
    expect(hasNegativePolarity("API error")).toBe(true);
    expect(hasNegativePolarity("request denied")).toBe(true);
    expect(hasNegativePolarity("Operation aborted")).toBe(true);
  });

  it("detects negative emojis", () => {
    expect(hasNegativePolarity("❌ broken")).toBe(true);
    expect(hasNegativePolarity("🚫 blocked")).toBe(true);
  });

  it("returns false for purely positive messages", () => {
    expect(hasNegativePolarity("Build succeeded")).toBe(false);
    expect(hasNegativePolarity("ビルド完了")).toBe(false);
    expect(hasNegativePolarity("All tests passing")).toBe(false);
  });
});

describe("stripMarkdown", () => {
  it("removes bold and italic markers but keeps content", () => {
    expect(stripMarkdown("**bold** and *italic* and __extra space__ and _again_")).toBe(
      "bold and italic and extra space and again",
    );
  });

  it("removes headers", () => {
    expect(stripMarkdown("# Title\n## Sub\n### Deep")).toBe("Title Sub Deep");
  });

  it("strips inline and fenced code", () => {
    expect(stripMarkdown("Use `npm test` to run")).toBe("Use npm test to run");
    expect(stripMarkdown("Result:\n```\nfoo\nbar\n```\nDone")).toBe("Result: Done");
  });

  it("removes list markers", () => {
    expect(stripMarkdown("- one\n- two\n* three\n1. four")).toBe("one two three four");
  });

  it("collapses tables", () => {
    expect(stripMarkdown("| Tool | Status |\n|---|---|\n| build | ok |")).toBe("Tool Status build ok");
  });

  it("keeps link text but drops URL", () => {
    expect(stripMarkdown("see [docs](https://example.com) for more")).toBe("see docs for more");
  });

  it("keeps emoji intact", () => {
    expect(stripMarkdown("**Done please** ✅🎉")).toBe("Done please ✅🎉");
  });

  it("strips strikethrough", () => {
    expect(stripMarkdown("~~deleted~~ kept")).toBe("deleted kept");
  });

  it("preserves snake_case identifiers", () => {
    expect(stripMarkdown("auth_helper_test.go passed")).toBe("auth_helper_test.go passed");
    expect(stripMarkdown("foo_bar_baz")).toBe("foo_bar_baz");
  });

  it("preserves Python dunder identifiers", () => {
    expect(stripMarkdown("__init__")).toBe("__init__");
    expect(stripMarkdown("Updated __init__.py and __main__.py")).toBe("Updated __init__.py and __main__.py");
  });

  it("preserves arithmetic and globs", () => {
    expect(stripMarkdown("2*3=6 result")).toBe("2*3=6 result");
    expect(stripMarkdown("rm *.log")).toBe("rm *.log");
  });
});

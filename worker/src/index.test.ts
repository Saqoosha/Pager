import { describe, it, expect, vi, beforeEach } from "vitest";
import { shortenWithLLM, type Env } from "./index";

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
});

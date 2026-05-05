import { describe, it, expect, vi } from "vitest";
import { shortenWithLLM, type Env } from "./index";

function mockEnv(responseText?: string, shouldThrow = false): Env {
  return {
    AI: {
      run: shouldThrow
        ? vi.fn().mockRejectedValue(new Error("AI unavailable"))
        : vi.fn().mockResolvedValue({ response: responseText }),
    } as unknown as Ai,
    REQUESTS: {} as KVNamespace,
    APNS_PRIVATE_KEY: "",
    APNS_KEY_ID: "",
    APNS_TEAM_ID: "",
    APNS_BUNDLE_ID: "",
    SHARED_SECRET: "",
    APNS_USE_SANDBOX: "true",
  };
}

describe("shortenWithLLM", () => {
  it("translates and shortens into Japanese under maxChars", async () => {
    const env = mockEnv("認証ミドルウェアのリファクタリング完了、テスト全通過");
    const result = await shortenWithLLM(
      env,
      "Claude Code has completed the requested refactoring of the authentication middleware and all 47 tests are now passing successfully",
      100,
    );
    expect(result).toBe("認証ミドルウェアのリファクタリング完了、テスト全通過");
  });

  it("returns original text on AI failure", async () => {
    const original = "Some long message that the AI will fail to shorten";
    const env = mockEnv(undefined, true);
    const result = await shortenWithLLM(env, original, 100);
    expect(result).toBe(original);
  });

  it("returns original text when AI response is empty", async () => {
    const original = "Another long message without AI response";
    const env = mockEnv(undefined);
    const result = await shortenWithLLM(env, original, 100);
    expect(result).toBe(original);
  });

  it("caps output at maxChars even when AI returns longer Japanese text", async () => {
    const env = mockEnv("あ".repeat(200));
    const result = await shortenWithLLM(env, "original long text", 100);
    expect(result.length).toBeLessThanOrEqual(100);
  });
});

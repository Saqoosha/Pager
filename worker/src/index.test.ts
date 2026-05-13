import { describe, it, expect, vi, beforeEach, beforeAll } from "vitest";
import { shortenWithLLM, stripMarkdown, sendPush, type Env } from "./index";

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

// In-memory KV that records every put for assertions.
function mockKV(initial: Record<string, string> = {}): {
  ns: KVNamespace;
  puts: Array<{ key: string; value: string }>;
} {
  const store = new Map<string, string>(Object.entries(initial));
  const puts: Array<{ key: string; value: string }> = [];
  const ns = {
    get: async (key: string) => store.get(key) ?? null,
    put: async (key: string, value: string) => {
      store.set(key, value);
      puts.push({ key, value });
    },
    delete: async (key: string) => {
      store.delete(key);
    },
  } as unknown as KVNamespace;
  return { ns, puts };
}

// Generate a real ECDSA P-256 key so generateAPNsJWT can sign the JWT without
// blowing up. Done once per file via beforeAll to avoid per-test cost.
let testPrivateKeyPem = "";
beforeAll(async () => {
  const keys = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const exported = await crypto.subtle.exportKey("pkcs8", keys.privateKey);
  const b64 = btoa(String.fromCharCode(...new Uint8Array(exported)));
  const wrapped = b64.match(/.{1,64}/g)!.join("\n");
  testPrivateKeyPem = `-----BEGIN PRIVATE KEY-----\n${wrapped}\n-----END PRIVATE KEY-----`;
});

function mockApnsEnv(useSandboxDefault: "true" | "false", kv: KVNamespace): Env {
  return {
    ANTHROPIC_API_KEY: "",
    REQUESTS: kv,
    APNS_PRIVATE_KEY: testPrivateKeyPem,
    APNS_KEY_ID: "TESTKEY01",
    APNS_TEAM_ID: "TESTTEAM01",
    APNS_BUNDLE_ID: "test.bundle.id",
    SHARED_SECRET: "",
    APNS_USE_SANDBOX: useSandboxDefault,
  };
}

function apnsOK(): Response {
  return new Response("", { status: 200 });
}

function apnsBadDeviceToken(): Response {
  return new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 });
}

function apnsOtherError(reason: string): Response {
  return new Response(JSON.stringify({ reason }), { status: 410 });
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

describe("sendPush APNs environment handling", () => {
  function captureFetchHosts(responses: Response[]): { spy: ReturnType<typeof vi.fn>; hosts: string[] } {
    const hosts: string[] = [];
    const spy = vi.fn().mockImplementation(async (url: string) => {
      hosts.push(new URL(url).host);
      const next = responses.shift();
      if (!next) throw new Error("captureFetchHosts: ran out of mocked responses");
      return next;
    });
    return { spy, hosts };
  }

  function apns400With(reason: string): Response {
    return new Response(JSON.stringify({ reason }), { status: 400 });
  }

  it("uses sandbox host when useSandbox=true is passed explicitly", async () => {
    const { spy, hosts } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns } = mockKV();
    await sendPush(mockApnsEnv("false", ns), "token-abc", {}, true);
    expect(hosts).toEqual(["api.sandbox.push.apple.com"]);
  });

  it("uses production host when useSandbox=false is passed explicitly", async () => {
    const { spy, hosts } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns } = mockKV();
    await sendPush(mockApnsEnv("true", ns), "token-abc", {}, false);
    expect(hosts).toEqual(["api.push.apple.com"]);
  });

  it("skips the KV cache when useSandbox is explicit", async () => {
    const { spy } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    await sendPush(mockApnsEnv("false", ns), "token-abc", {}, true);
    expect(puts).toEqual([]);
  });

  it("auto-detect: no cache + APNS_USE_SANDBOX=false → tries production, caches on success", async () => {
    const { spy, hosts } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("false", ns), "token-xyz", {});
    expect(result.ok).toBe(true);
    expect(hosts).toEqual(["api.push.apple.com"]);
    expect(puts).toEqual([{ key: "apns_env:token-xyz", value: "production" }]);
  });

  it("auto-detect: no cache + APNS_USE_SANDBOX=true → tries sandbox, flips to production on BadDeviceToken", async () => {
    const { spy, hosts } = captureFetchHosts([apnsBadDeviceToken(), apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("true", ns), "token-flip2", {});
    expect(result.ok).toBe(true);
    expect(hosts).toEqual(["api.sandbox.push.apple.com", "api.push.apple.com"]);
    expect(puts).toEqual([{ key: "apns_env:token-flip2", value: "production" }]);
  });

  it("auto-detect: cached sandbox env wins over APNS_USE_SANDBOX default", async () => {
    const { spy, hosts } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV({ "apns_env:token-xyz": "sandbox" });
    await sendPush(mockApnsEnv("false", ns), "token-xyz", {});
    expect(hosts).toEqual(["api.sandbox.push.apple.com"]);
    // Already-correct cache: no rewrite needed.
    expect(puts).toEqual([]);
  });

  it("auto-detect: BadDeviceToken triggers retry against opposite host and caches it", async () => {
    const { spy, hosts } = captureFetchHosts([apnsBadDeviceToken(), apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("false", ns), "token-flip", {});
    expect(result.ok).toBe(true);
    expect(hosts).toEqual(["api.push.apple.com", "api.sandbox.push.apple.com"]);
    expect(puts).toEqual([{ key: "apns_env:token-flip", value: "sandbox" }]);
  });

  it("auto-detect: DeviceTokenNotForTopic also triggers retry", async () => {
    const { spy, hosts } = captureFetchHosts([apns400With("DeviceTokenNotForTopic"), apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("false", ns), "token-topic", {});
    expect(result.ok).toBe(true);
    expect(hosts).toEqual(["api.push.apple.com", "api.sandbox.push.apple.com"]);
    expect(puts).toEqual([{ key: "apns_env:token-topic", value: "sandbox" }]);
  });

  it("auto-detect: corrects a stale cache after a BadDeviceToken retry", async () => {
    const { spy, hosts } = captureFetchHosts([apnsBadDeviceToken(), apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV({ "apns_env:token-stale": "sandbox" });
    await sendPush(mockApnsEnv("false", ns), "token-stale", {});
    expect(hosts).toEqual(["api.sandbox.push.apple.com", "api.push.apple.com"]);
    expect(puts).toEqual([{ key: "apns_env:token-stale", value: "production" }]);
  });

  it("auto-detect: non-BadDeviceToken 4xx is not retried", async () => {
    const { spy, hosts } = captureFetchHosts([apnsOtherError("Unregistered")]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("false", ns), "token-dead", {});
    expect(result.ok).toBe(false);
    expect(result.status).toBe(410);
    expect(hosts).toEqual(["api.push.apple.com"]);
    expect(puts).toEqual([]);
  });

  it("auto-detect: 400 with non-retryable reason is not retried", async () => {
    const { spy, hosts } = captureFetchHosts([apns400With("BadCertificate")]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("false", ns), "token-cert", {});
    expect(result.status).toBe(400);
    expect(hosts).toEqual(["api.push.apple.com"]);
    expect(puts).toEqual([]);
  });

  it("auto-detect: 400 with non-JSON body falls through without retry", async () => {
    const malformedBody = new Response("<html>Bad Gateway</html>", { status: 400 });
    const { spy, hosts } = captureFetchHosts([malformedBody]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("false", ns), "token-html", {});
    expect(result.status).toBe(400);
    expect(hosts).toEqual(["api.push.apple.com"]);
    expect(puts).toEqual([]);
  });

  it("auto-detect: 5xx server error is not retried, no cache write", async () => {
    const { spy, hosts } = captureFetchHosts([new Response("", { status: 503 })]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("false", ns), "token-busy", {});
    expect(result.status).toBe(503);
    expect(hosts).toEqual(["api.push.apple.com"]);
    expect(puts).toEqual([]);
  });

  it("auto-detect: BadDeviceToken on retry also fails — returns the retry response without re-caching", async () => {
    const { spy, hosts } = captureFetchHosts([apnsBadDeviceToken(), apnsBadDeviceToken()]);
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    const result = await sendPush(mockApnsEnv("false", ns), "token-dead", {});
    expect(result.ok).toBe(false);
    expect(hosts).toEqual(["api.push.apple.com", "api.sandbox.push.apple.com"]);
    expect(puts).toEqual([]);
  });

  it("auto-detect: network exception on retry propagates without cache write", async () => {
    const spy = vi.fn()
      .mockResolvedValueOnce(apnsBadDeviceToken())
      .mockRejectedValueOnce(new Error("connection reset"));
    vi.stubGlobal("fetch", spy);
    const { ns, puts } = mockKV();
    await expect(sendPush(mockApnsEnv("false", ns), "token-flap", {})).rejects.toThrow("connection reset");
    expect(puts).toEqual([]);
  });

  it("auto-detect: KV read failure falls through to seed env and still succeeds", async () => {
    const { spy, hosts } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const throwingNs = {
      get: async () => {
        throw new Error("KV transient outage");
      },
      put: async () => {},
      delete: async () => {},
    } as unknown as KVNamespace;
    const result = await sendPush(mockApnsEnv("false", throwingNs), "token-kvdown", {});
    expect(result.ok).toBe(true);
    // Seed env was production (APNS_USE_SANDBOX=false) since the read failed.
    expect(hosts).toEqual(["api.push.apple.com"]);
  });

  it("auto-detect: KV write failure is swallowed; push still returns OK", async () => {
    const { spy } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const writeFailNs = {
      get: async () => null,
      put: async () => {
        throw new Error("KV write quota exceeded");
      },
      delete: async () => {},
    } as unknown as KVNamespace;
    const result = await sendPush(mockApnsEnv("false", writeFailNs), "token-noput", {});
    expect(result.ok).toBe(true);
  });

  it("auto-detect: writes the cache entry with a 30-day expirationTtl", async () => {
    const { spy } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const recordedPuts: Array<{ key: string; value: string; options?: unknown }> = [];
    const recordingNs = {
      get: async () => null,
      put: async (key: string, value: string, options?: unknown) => {
        recordedPuts.push({ key, value, options });
      },
      delete: async () => {},
    } as unknown as KVNamespace;
    await sendPush(mockApnsEnv("false", recordingNs), "token-ttl", {});
    expect(recordedPuts).toEqual([
      {
        key: "apns_env:token-ttl",
        value: "production",
        options: { expirationTtl: 60 * 60 * 24 * 30 },
      },
    ]);
  });

  it("auto-detect: treats body.sandbox=null as undefined and falls through to auto-detect", async () => {
    const { spy, hosts } = captureFetchHosts([apnsOK()]);
    vi.stubGlobal("fetch", spy);
    const { ns } = mockKV();
    // Cast through unknown to simulate JSON null reaching this function.
    await sendPush(mockApnsEnv("true", ns), "token-null", {}, null as unknown as boolean);
    expect(hosts).toEqual(["api.sandbox.push.apple.com"]);
  });
});

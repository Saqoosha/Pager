interface Env {
  REQUESTS: KVNamespace;
  APNS_PRIVATE_KEY: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  SHARED_SECRET: string;
  APNS_USE_SANDBOX: "true" | "false";
}

type Decision = "allow" | "deny" | "allowAlways";
const VALID_DECISIONS: Decision[] = ["allow", "deny", "allowAlways"];

interface PendingRequest {
  requestId: string;
  toolName: string;
  toolInput: string;
  project: string;
  decision?: Decision;
  timestamp: number;
}

// --- APNs JWT ---

function base64url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlString(str: string): string {
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importAPNsKey(pem: string): Promise<CryptoKey> {
  const lines = pem.split("\n").filter((l) => !l.startsWith("-----") && l.trim());
  const raw = Uint8Array.from(atob(lines.join("")), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", raw, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

async function generateAPNsJWT(env: Env): Promise<string> {
  const header = base64urlString(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const now = Math.floor(Date.now() / 1000);
  const claims = base64urlString(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const unsigned = `${header}.${claims}`;
  const key = await importAPNsKey(env.APNS_PRIVATE_KEY);
  // Web Crypto ECDSA returns raw r||s format directly (no DER-to-raw conversion needed)
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64url(signature)}`;
}

async function sendPush(env: Env, deviceToken: string, payload: object): Promise<Response> {
  const jwt = await generateAPNsJWT(env);
  const apnsHost = env.APNS_USE_SANDBOX === "true" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return fetch(`https://${apnsHost}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
}

// --- Auth (timing-safe comparison) ---

async function checkAuth(request: Request, env: Env): Promise<boolean> {
  if (!env.SHARED_SECRET) return false;
  const auth = request.headers.get("Authorization") ?? "";
  const expected = `Bearer ${env.SHARED_SECRET}`;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(auth)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const viewA = new Uint8Array(a);
  const viewB = new Uint8Array(b);
  if (viewA.length !== viewB.length) return false;
  let result = 0;
  for (let i = 0; i < viewA.length; i++) result |= viewA[i]! ^ viewB[i]!;
  return result === 0;
}

function unauthorized(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });
}

function badRequest(message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status: 400,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });
}

async function parseJSON<T>(request: Request): Promise<T | null> {
  try {
    return (await request.json()) as T;
  } catch {
    return null;
  }
}

// --- Routes ---

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    // CORS preflight (for browser-based debugging or web clients)
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization",
        },
      });
    }

    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Content-Type": "application/json",
    };

    try {
      if (!(await checkAuth(request, env))) return unauthorized();

      // POST /register — store device token
      if (path === "/register" && request.method === "POST") {
        const body = await parseJSON<{ token: string }>(request);
        if (!body?.token) return badRequest("token required");
        // Validate APNs token format: lowercase hex string (length varies by device/OS)
        if (!/^[0-9a-f]+$/.test(body.token)) return badRequest("invalid token format");
        await env.REQUESTS.put("device_token", body.token);
        return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
      }

      // POST /request — receive permission request from hook, send push
      if (path === "/request" && request.method === "POST") {
        const body = await parseJSON<{
          requestId: string;
          toolName: string;
          toolInput: string;
          project: string;
        }>(request);

        if (!body?.requestId || !body.toolName) return badRequest("requestId and toolName required");

        const deviceToken = await env.REQUESTS.get("device_token");
        if (!deviceToken) {
          return new Response(JSON.stringify({ error: "no device registered" }), { status: 503, headers: corsHeaders });
        }

        const pending: PendingRequest = {
          requestId: body.requestId,
          toolName: body.toolName,
          toolInput: body.toolInput || "",
          project: body.project || "",
          timestamp: Date.now(),
        };
        await env.REQUESTS.put(`request:${body.requestId}`, JSON.stringify(pending), { expirationTtl: 300 });

        const inputPreview = (body.toolInput || "").length > 200 ? body.toolInput.slice(0, 200) + "…" : (body.toolInput || "");

        const apnsPayload = {
          aps: {
            alert: {
              title: `[${body.project || "?"}] ${body.toolName}`,
              body: inputPreview,
            },
            sound: "default",
            category: "PERMISSION_REQUEST",
            "interruption-level": "time-sensitive",
            "mutable-content": 1,
          },
          requestId: body.requestId,
        };

        const pushResult = await sendPush(env, deviceToken, apnsPayload);
        if (!pushResult.ok) {
          const err = await pushResult.text();
          return new Response(JSON.stringify({ error: "apns_failed", detail: err, status: pushResult.status }), {
            status: 502,
            headers: corsHeaders,
          });
        }

        return new Response(JSON.stringify({ ok: true, requestId: body.requestId }), { headers: corsHeaders });
      }

      // POST /response — receive decision from iOS app
      if (path === "/response" && request.method === "POST") {
        const body = await parseJSON<{ requestId: string; decision: string }>(request);
        if (!body?.requestId || !body.decision) return badRequest("requestId and decision required");
        if (!VALID_DECISIONS.includes(body.decision as Decision)) {
          return badRequest(`invalid decision: must be one of ${VALID_DECISIONS.join(", ")}`);
        }

        const key = `request:${body.requestId}`;
        const raw = await env.REQUESTS.get(key);
        if (!raw) {
          return new Response(JSON.stringify({ error: "request not found or expired" }), {
            status: 404,
            headers: corsHeaders,
          });
        }
        let pending: PendingRequest;
        try {
          pending = JSON.parse(raw);
        } catch {
          return new Response(JSON.stringify({ error: "corrupted request data" }), {
            status: 500,
            headers: corsHeaders,
          });
        }
        pending.decision = body.decision as Decision;
        await env.REQUESTS.put(key, JSON.stringify(pending), { expirationTtl: 60 });
        return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
      }

      // GET /status/:requestId — poll for decision
      if (path.startsWith("/status/") && request.method === "GET") {
        const requestId = path.slice("/status/".length);
        if (!requestId || requestId.includes("/")) {
          return badRequest("invalid requestId");
        }
        const raw = await env.REQUESTS.get(`request:${requestId}`);
        if (!raw) {
          return new Response(JSON.stringify({ status: "expired" }), { headers: corsHeaders });
        }
        let pending: PendingRequest;
        try {
          pending = JSON.parse(raw);
        } catch {
          return new Response(JSON.stringify({ status: "expired" }), { headers: corsHeaders });
        }
        if (pending.decision) {
          // Let TTL expire the entry — immediate deletion risks the poller missing
          // the decision if its HTTP response is lost after we delete here
          return new Response(JSON.stringify({ status: "decided", decision: pending.decision }), {
            headers: corsHeaders,
          });
        }
        return new Response(JSON.stringify({ status: "pending" }), { headers: corsHeaders });
      }

      // POST /notify — send plain notification (no action buttons)
      if (path === "/notify" && request.method === "POST") {
        const body = await parseJSON<{ title: string; message: string }>(request);
        if (!body) return badRequest("invalid JSON body");
        const deviceToken = await env.REQUESTS.get("device_token");
        if (!deviceToken) {
          return new Response(JSON.stringify({ error: "no device registered" }), { status: 503, headers: corsHeaders });
        }
        const payload = {
          aps: {
            alert: {
              title: body.title || "Canopy Companion",
              body: body.message || "",
            },
            sound: "default",
            "interruption-level": "time-sensitive",
          },
        };
        const pushResult = await sendPush(env, deviceToken, payload);
        if (!pushResult.ok) {
          const err = await pushResult.text();
          return new Response(JSON.stringify({ error: "apns_failed", detail: err, status: pushResult.status }), {
            status: 502,
            headers: corsHeaders,
          });
        }
        return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
      }

      // POST /test — send test notification
      if (path === "/test" && request.method === "POST") {
        const deviceToken = await env.REQUESTS.get("device_token");
        if (!deviceToken) {
          return new Response(JSON.stringify({ error: "no device registered" }), { status: 503, headers: corsHeaders });
        }
        const testPayload = {
          aps: {
            alert: {
              title: "Canopy Companion",
              body: "テスト通知。ボタンが表示されるか確認。",
            },
            sound: "default",
            category: "PERMISSION_REQUEST",
            "interruption-level": "time-sensitive",
          },
          requestId: crypto.randomUUID(),
        };
        const pushResult = await sendPush(env, deviceToken, testPayload);
        if (!pushResult.ok) {
          const err = await pushResult.text();
          return new Response(JSON.stringify({ error: "apns_failed", detail: err, status: pushResult.status }), {
            status: 502,
            headers: corsHeaders,
          });
        }
        return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
      }

      return new Response(JSON.stringify({ error: "not found" }), { status: 404, headers: corsHeaders });
    } catch (e) {
      console.error("Unhandled error:", e);
      return new Response(JSON.stringify({ error: "internal_error", detail: String(e) }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
  },
};

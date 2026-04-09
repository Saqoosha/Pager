interface Env {
  REQUESTS: KVNamespace;
  APNS_PRIVATE_KEY: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  SHARED_SECRET: string;
  APNS_USE_SANDBOX: string;
}

interface PendingRequest {
  requestId: string;
  toolName: string;
  toolInput: string;
  project: string;
  decision?: string;
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
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(unsigned),
  );
  // Convert DER signature to raw r||s format is not needed — Web Crypto returns raw format
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

// --- Auth ---

function checkAuth(request: Request, env: Env): boolean {
  const auth = request.headers.get("Authorization");
  return auth === `Bearer ${env.SHARED_SECRET}`;
}

function unauthorized(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
}

// --- Routes ---

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    // CORS for iOS app
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

    if (!checkAuth(request, env)) return unauthorized();

    // POST /register - store device token
    if (path === "/register" && request.method === "POST") {
      const body = (await request.json()) as { token: string };
      if (!body.token) {
        return new Response(JSON.stringify({ error: "token required" }), { status: 400, headers: corsHeaders });
      }
      await env.REQUESTS.put("device_token", body.token);
      return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
    }

    // POST /request - receive permission request from hook, send push
    if (path === "/request" && request.method === "POST") {
      const body = (await request.json()) as {
        requestId: string;
        toolName: string;
        toolInput: string;
        project: string;
      };

      const deviceToken = await env.REQUESTS.get("device_token");
      if (!deviceToken) {
        return new Response(JSON.stringify({ error: "no device registered" }), { status: 503, headers: corsHeaders });
      }

      // Store pending request (TTL 5 minutes)
      const pending: PendingRequest = {
        requestId: body.requestId,
        toolName: body.toolName,
        toolInput: body.toolInput,
        project: body.project,
        timestamp: Date.now(),
      };
      await env.REQUESTS.put(`request:${body.requestId}`, JSON.stringify(pending), { expirationTtl: 300 });

      // Truncate toolInput for notification body
      const inputPreview = body.toolInput.length > 200 ? body.toolInput.slice(0, 200) + "…" : body.toolInput;

      // Send APNs push
      const apnsPayload = {
        aps: {
          alert: {
            title: `[${body.project}] ${body.toolName}`,
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

    // POST /response - receive decision from iOS app
    if (path === "/response" && request.method === "POST") {
      const body = (await request.json()) as { requestId: string; decision: string };
      const key = `request:${body.requestId}`;
      const raw = await env.REQUESTS.get(key);
      if (!raw) {
        return new Response(JSON.stringify({ error: "request not found or expired" }), {
          status: 404,
          headers: corsHeaders,
        });
      }
      const pending: PendingRequest = JSON.parse(raw);
      pending.decision = body.decision;
      await env.REQUESTS.put(key, JSON.stringify(pending), { expirationTtl: 60 });
      return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
    }

    // GET /status/:requestId - poll for decision
    if (path.startsWith("/status/") && request.method === "GET") {
      const requestId = path.split("/status/")[1];
      const raw = await env.REQUESTS.get(`request:${requestId}`);
      if (!raw) {
        return new Response(JSON.stringify({ status: "expired" }), { headers: corsHeaders });
      }
      const pending: PendingRequest = JSON.parse(raw);
      if (pending.decision) {
        // Clean up
        await env.REQUESTS.delete(`request:${requestId}`);
        return new Response(JSON.stringify({ status: "decided", decision: pending.decision }), {
          headers: corsHeaders,
        });
      }
      return new Response(JSON.stringify({ status: "pending" }), { headers: corsHeaders });
    }

    // POST /notify - send plain notification (no action buttons)
    if (path === "/notify" && request.method === "POST") {
      const body = (await request.json()) as { title: string; message: string };
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

    // POST /test - send test notification
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
        requestId: "test",
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
  },
};

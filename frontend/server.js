import express from "express";
import pinoHttp from "pino-http";
import fetch from "node-fetch";

const PORT = parseInt(process.env.PORT || "3000", 10);
const BACKEND_URL = process.env.BACKEND_URL;
if (!BACKEND_URL) {
  console.error("BACKEND_URL env var is required");
  process.exit(1);
}

const app = express();
app.use(pinoHttp({
  formatters: { level: (label) => ({ level: label }) },
  timestamp: () => `,"ts":"${new Date().toISOString()}"`,
}));
app.use(express.json());

app.get("/healthz", (_req, res) => res.json({ status: "ok" }));

app.get("/readyz", async (_req, res) => {
  try {
    const r = await fetch(`${BACKEND_URL}/healthz`, { timeout: 2000 });
    if (!r.ok) throw new Error(`backend ${r.status}`);
    res.json({ status: "ready" });
  } catch (e) {
    res.status(503).json({ status: "unready", error: e.message });
  }
});

app.use("/api", async (req, res) => {
  try {
    const upstream = await fetch(`${BACKEND_URL}${req.url}`, {
      method: req.method,
      headers: { "content-type": "application/json" },
      body: ["GET", "HEAD"].includes(req.method) ? undefined : JSON.stringify(req.body),
    });
    const body = await upstream.text();
    res.status(upstream.status).type(upstream.headers.get("content-type") || "application/json").send(body);
  } catch (e) {
    res.status(502).json({ error: "bad gateway", detail: e.message });
  }
});

app.use(express.static("dist"));

app.listen(PORT, "0.0.0.0", () => {
  console.log(JSON.stringify({ level: "info", ts: new Date().toISOString(), msg: `frontend listening on ${PORT}` }));
});

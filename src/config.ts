/**
 * Every setting is read once at boot so a misconfigured container dies immediately
 * instead of failing later on a request path.
 */

export const MAX_LATENCY_MS = 120_000;

class ConfigError extends Error {}

function readString(name: string, fallback: string): string {
  const raw = process.env[name];
  return raw === undefined || raw.trim() === "" ? fallback : raw.trim();
}

function readInt(name: string, fallback: number, min: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;

  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new ConfigError(`${name} must be a whole number between ${min} and ${max}. Got "${raw}".`);
  }
  return value;
}

function readRate(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;

  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new ConfigError(`${name} must be a number between 0 and 1. Got "${raw}".`);
  }
  return value;
}

function readChaosToken(): string {
  const raw = process.env.CHAOS_TOKEN?.trim();
  if (!raw) {
    throw new ConfigError(
      "CHAOS_TOKEN is required. /admin/chaos changes how the service behaves, so it is never left open.",
    );
  }
  if (raw.length < 32) {
    throw new ConfigError(`CHAOS_TOKEN must be at least 32 characters. Got ${raw.length}.`);
  }
  return raw;
}

function build() {
  const requestDeadlineMs = readInt("REQUEST_DEADLINE_MS", 3_000, 100, MAX_LATENCY_MS);

  return {
    port: readInt("PORT", 8080, 1, 65_535),
    host: readString("HOST", "0.0.0.0"),
    nodeEnv: readString("NODE_ENV", "development"),
    logLevel: readString("LOG_LEVEL", "info"),
    serviceName: readString("SERVICE_NAME", "timeout-service"),
    serviceVersion: readString("SERVICE_VERSION", "1.0.0"),
    requestDeadlineMs,
    // Readiness has its own, tighter budget so a degraded ledger shows up before the
    // business routes start returning 504s.
    readinessDeadlineMs: Math.min(1_000, requestDeadlineMs),
    upstreamLatencyMs: readInt("UPSTREAM_LATENCY_MS", 200, 0, MAX_LATENCY_MS),
    upstreamJitterMs: readInt("UPSTREAM_JITTER_MS", 80, 0, MAX_LATENCY_MS),
    upstreamTimeoutRate: readRate("UPSTREAM_TIMEOUT_RATE", 0),
    chaosToken: readChaosToken(),
  } as const;
}

let resolved: ReturnType<typeof build>;

try {
  resolved = build();
} catch (error) {
  if (error instanceof ConfigError) {
    process.stderr.write(`configuration error: ${error.message}\n`);
    process.exit(1);
  }
  throw error;
}

export type Config = ReturnType<typeof build>;
export const config: Config = resolved;

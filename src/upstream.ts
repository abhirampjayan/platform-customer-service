import { MAX_LATENCY_MS, config } from "./config.js";

export const UPSTREAM_NAME = "ledger";

export type ChaosProfile = {
  latencyMs: number;
  jitterMs: number;
  timeoutRate: number;
};

export class UpstreamTimeoutError extends Error {
  readonly upstream = UPSTREAM_NAME;

  constructor(
    readonly operation: string,
    readonly deadlineMs: number,
    readonly elapsedMs: number,
  ) {
    super(`${UPSTREAM_NAME} did not answer within ${deadlineMs}ms`);
    this.name = "UpstreamTimeoutError";
  }
}

let profile: ChaosProfile = {
  latencyMs: config.upstreamLatencyMs,
  jitterMs: config.upstreamJitterMs,
  timeoutRate: config.upstreamTimeoutRate,
};

export function getChaosProfile(): ChaosProfile {
  return { ...profile };
}

export function setChaosProfile(patch: Partial<ChaosProfile>): ChaosProfile {
  profile = { ...profile, ...patch };
  return getChaosProfile();
}

class AbortedError extends Error {}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    // Never hold the event loop open for a call nobody is waiting on any more.
    timer.unref?.();

    function onAbort() {
      clearTimeout(timer);
      reject(new AbortedError());
    }

    signal.addEventListener("abort", onAbort, { once: true });
  });
}

function plannedLatency(override?: number): number {
  if (override !== undefined) return override;
  if (Math.random() < profile.timeoutRate) return MAX_LATENCY_MS;

  const jitter = profile.jitterMs === 0 ? 0 : Math.round(Math.random() * profile.jitterMs);
  return Math.min(profile.latencyMs + jitter, MAX_LATENCY_MS);
}

export type LedgerResult = {
  upstream: typeof UPSTREAM_NAME;
  operation: string;
  latencyMs: number;
};

/**
 * Stands in for the downstream ledger the real service would call. It answers after a
 * configurable delay and is abandoned — not merely ignored — once the deadline passes.
 */
export async function callLedger(
  operation: string,
  deadlineMs: number,
  latencyOverrideMs?: number,
): Promise<LedgerResult> {
  const latencyMs = plannedLatency(latencyOverrideMs);
  const controller = new AbortController();
  const startedAt = performance.now();

  const deadline = setTimeout(() => controller.abort(), deadlineMs);
  deadline.unref?.();

  try {
    await sleep(latencyMs, controller.signal);
    return { upstream: UPSTREAM_NAME, operation, latencyMs };
  } catch (error) {
    if (error instanceof AbortedError) {
      throw new UpstreamTimeoutError(operation, deadlineMs, Math.round(performance.now() - startedAt));
    }
    throw error;
  } finally {
    clearTimeout(deadline);
  }
}

import { MAX_LATENCY_MS, config } from "./config.js";
export const UPSTREAM_NAME = "ledger";
export class UpstreamTimeoutError extends Error {
    operation;
    deadlineMs;
    elapsedMs;
    upstream = UPSTREAM_NAME;
    constructor(operation, deadlineMs, elapsedMs) {
        super(`${UPSTREAM_NAME} did not answer within ${deadlineMs}ms`);
        this.operation = operation;
        this.deadlineMs = deadlineMs;
        this.elapsedMs = elapsedMs;
        this.name = "UpstreamTimeoutError";
    }
}
let profile = {
    latencyMs: config.upstreamLatencyMs,
    jitterMs: config.upstreamJitterMs,
    timeoutRate: config.upstreamTimeoutRate,
};
export function getChaosProfile() {
    return { ...profile };
}
export function setChaosProfile(patch) {
    profile = { ...profile, ...patch };
    return getChaosProfile();
}
class AbortedError extends Error {
}
function sleep(ms, signal) {
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
function plannedLatency(override) {
    if (override !== undefined)
        return override;
    if (Math.random() < profile.timeoutRate)
        return MAX_LATENCY_MS;
    const jitter = profile.jitterMs === 0 ? 0 : Math.round(Math.random() * profile.jitterMs);
    return Math.min(profile.latencyMs + jitter, MAX_LATENCY_MS);
}
/**
 * Stands in for the downstream ledger the real service would call. It answers after a
 * configurable delay and is abandoned — not merely ignored — once the deadline passes.
 */
export async function callLedger(operation, deadlineMs, latencyOverrideMs) {
    const latencyMs = plannedLatency(latencyOverrideMs);
    const controller = new AbortController();
    const startedAt = performance.now();
    const deadline = setTimeout(() => controller.abort(), deadlineMs);
    deadline.unref?.();
    try {
        await sleep(latencyMs, controller.signal);
        return { upstream: UPSTREAM_NAME, operation, latencyMs };
    }
    catch (error) {
        if (error instanceof AbortedError) {
            throw new UpstreamTimeoutError(operation, deadlineMs, Math.round(performance.now() - startedAt));
        }
        throw error;
    }
    finally {
        clearTimeout(deadline);
    }
}
//# sourceMappingURL=upstream.js.map
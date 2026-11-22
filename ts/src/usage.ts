import type { UsageEntry } from "./types.js";

export interface Totals {
  calls: number;
  cost: number;
  tokensIn: number;
  tokensOut: number;
  errors: number;
  byUseCase: Record<string, { calls: number; cost: number }>;
  byModel: Record<string, { calls: number; cost: number }>;
}

export const emptyTotals = (): Totals => ({ calls: 0, cost: 0, tokensIn: 0, tokensOut: 0, errors: 0, byUseCase: {}, byModel: {} });

export interface UsageSnapshot {
  allTime: Totals;
  byDay: Record<string, Totals>;
  calls: UsageEntry[];
}

/** Spend tracking: per-call log, totals per session / day / all time. Persist with snapshot()/restore(). */
export class UsageTracker {
  session = emptyTotals();
  allTime = emptyTotals();
  byDay: Record<string, Totals> = {};
  calls: UsageEntry[] = [];
  private listeners = new Set<(e: UsageEntry) => void>();
  constructor(readonly logCap = 500) {}

  record(e: UsageEntry): void {
    this.calls.push(e);
    if (this.calls.length > this.logCap) this.calls.splice(0, this.calls.length - this.logCap);
    const day = e.time.slice(0, 10);
    this.byDay[day] ??= emptyTotals();
    for (const t of [this.session, this.allTime, this.byDay[day]]) add(t, e);
    for (const l of this.listeners) l(e);
  }

  onRecord(fn: (e: UsageEntry) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  today(): Totals {
    return this.byDay[new Date().toISOString().slice(0, 10)] ?? emptyTotals();
  }

  snapshot(): UsageSnapshot {
    return { allTime: this.allTime, byDay: this.byDay, calls: this.calls };
  }

  restore(s: Partial<UsageSnapshot>): void {
    this.allTime = s.allTime ?? emptyTotals();
    this.byDay = s.byDay ?? {};
    this.calls = s.calls ?? [];
  }
}

function add(t: Totals, e: UsageEntry): void {
  t.calls++;
  t.cost += e.cost;
  t.tokensIn += e.tokensIn;
  t.tokensOut += e.tokensOut;
  if (e.status !== "ok") t.errors++;
  for (const [g, k] of [[t.byUseCase, e.useCase], [t.byModel, e.model]] as const) {
    const row = (g[k] ??= { calls: 0, cost: 0 });
    row.calls++;
    row.cost += e.cost;
  }
}

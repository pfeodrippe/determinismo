// SPDX-License-Identifier: MIT
// Types of the determinismo SDK for JavaScript (determinismo.js): see it for each function.

export type JSONValue = string | number | bigint | boolean | null | JSONValue[] | { [key: string]: JSONValue };
export type Details = { [key: string]: JSONValue } | undefined;
export type Kind = "always" | "always_or_unreachable" | "sometimes" | "reachable" | "unreachable";

export interface Generator {
  nextU64(): bigint;
  random(): number;
  below(count: number): number;
  below(count: bigint): bigint;
  choice<T>(items: readonly T[]): T;
  shuffle<T>(items: T[]): T[];
}

export function inside(): boolean;

export function randomBytes(count: number): Buffer;
export function randomU64(): bigint;
export function randomBelow(count: number): number;
export function randomBelow(count: bigint): bigint;
export function randomChoice<T>(items: readonly T[]): T;
export function random(): number;
export function rng(): Generator;
export function prng(): Generator;

export function decide(name: string, options: readonly unknown[]): number;
export function randomBelowNamed(name: string, count: number): number;
export function randomBelowNamed(name: string, count: bigint): bigint;
export function buggify(name: string): boolean;
export function buggifyPause(name: string): void;
export function buggifyPauseAsync(name: string): Promise<void>;

export function setAssertionEvents(mode: "every" | "first"): void;
export function always(condition: unknown, message: string, details?: Details): void;
export function alwaysOrUnreachable(condition: unknown, message: string, details?: Details): void;
export function sometimes(condition: unknown, message: string, details?: Details): void;
export function reachable(message: string, details?: Details): void;
export function unreachable(message: string, details?: Details): void;

type Compare = (left: number | bigint, right: number | bigint, message: string, details?: Details) => void;
export const alwaysGreaterThan: Compare;
export const alwaysGreaterThanOrEqual: Compare;
export const alwaysLessThan: Compare;
export const alwaysLessThanOrEqual: Compare;
export const sometimesGreaterThan: Compare;
export const sometimesGreaterThanOrEqual: Compare;
export const sometimesLessThan: Compare;
export const sometimesLessThanOrEqual: Compare;
export function alwaysSome(conditions: { [name: string]: boolean }, message: string, details?: Details): void;
export function sometimesAll(conditions: { [name: string]: boolean }, message: string, details?: Details): void;

export interface CatalogEntry {
  kind: Kind;
  message: string;
  file: string | null;
}
export function declare(kind: Kind, message: string, file?: string | null): void;
export function catalog(file: string): void;
export function catalogAssertions(): CatalogEntry[];
export function catalogWrite(stream?: { write(text: string): unknown }): void;

export function setupComplete(details?: Details): void;
export function event(name: string, details?: Details): void;
/** An objective for exploration: each bucket (its strings and booleans) keeps its best state. */
export function optimize(
  message: string,
  bucket: Details | null,
  value: number | bigint,
  goal?: "maximize" | "minimize",
): void;
export function output(object: { [key: string]: JSONValue }): void;

export function stopFaults(seconds: number): void;
export function fault(request: { kind: string; [key: string]: JSONValue }): void;
/** Aims the fault injector at `node` from now on, until another call ("" for none): half its
 * faults involve it, each a decision strategies see and replays repeat (a primary, a leader). */
export function faultAim(node: string): void;
export function coverageStart(options?: { paths?: string[]; intervalMs?: number }): void;

// Antithesis's TypeScript SDK's names.
export const alwaysGreaterThanOrEqualTo: Compare;
export const alwaysLessThanOrEqualTo: Compare;
export const sometimesGreaterThanOrEqualTo: Compare;
export const sometimesLessThanOrEqualTo: Compare;
export function sendEvent(name: string, details?: Details): void;

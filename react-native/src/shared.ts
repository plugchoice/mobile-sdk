import type { NativeLinkAction } from './PlugchoiceModule';
import type { PlugchoiceErrorCode } from './types';

export function codedError(code: PlugchoiceErrorCode, message: string): Error & { code: PlugchoiceErrorCode } {
  return Object.assign(new Error(message), { code });
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * `{ action, chargerId?, siteId? }` from anything shaped like it, with empty ids left out (as the
 * native SDKs do), or `undefined` when there is no action.
 */
export function toLinkAction(value: unknown): NativeLinkAction | undefined {
  if (!isRecord(value) || typeof value.action !== 'string' || value.action.trim() === '') {
    return undefined;
  }
  const action: NativeLinkAction = { action: value.action };
  if (typeof value.chargerId === 'string' && value.chargerId !== '') {
    action.chargerId = value.chargerId;
  }
  if (typeof value.siteId === 'string' && value.siteId !== '') {
    action.siteId = value.siteId;
  }
  return action;
}

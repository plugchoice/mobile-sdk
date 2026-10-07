import { currentConfig } from './configure';
import PlugchoiceModule, { type NativeLinkAction } from './PlugchoiceModule';
import { codedError, isRecord, toLinkAction } from './shared';
import type { Device, LinkAction, LinkError, LinkResult, LinkStatus } from './types';

/** A Link screen is open (set until the native promise settles). */
let isOpen = false;

/**
 * Opens Link, the onboarding screen, for `action` full screen, and resolves with the result once
 * it is closed. While it is open the SDK calls the `fetchClientSecret` given to
 * {@link configurePlugchoice} with this action.
 *
 * ```ts
 * const result = await openLink({ action: 'network', chargerId });
 * ```
 *
 * Throws a `TypeError` for an action that isn't `{ action: string, chargerId?, siteId? }`. Rejects
 * (with `code` set, see {@link PlugchoiceErrorCode}) when Link can't be shown: the native module
 * isn't in this build, `configurePlugchoice` wasn't called, a Link screen is already open (one at
 * a time), or there is no screen to show it from.
 */
export async function openLink(action: LinkAction): Promise<LinkResult> {
  const request = checkedAction(action);
  if (!PlugchoiceModule) {
    throw codedError(
      'ERR_PLUGCHOICE_UNAVAILABLE',
      'The Plugchoice native module is not in this build. It needs a development or release build of ' +
        'your app (not Expo Go or web), rebuilt after installing @plugchoice/react-native.'
    );
  }
  const config = currentConfig();
  if (!config) {
    throw codedError(
      'ERR_PLUGCHOICE_NOT_CONFIGURED',
      'Call configurePlugchoice({ fetchClientSecret }) before openLink: Link needs a client secret from your server.'
    );
  }
  if (isOpen) {
    throw codedError('ERR_LINK_ALREADY_OPEN', 'A Plugchoice Link screen is already open.');
  }
  isOpen = true;
  try {
    const payload = await PlugchoiceModule.openLink(
      request,
      config.hostOverride === undefined ? {} : { hostOverride: config.hostOverride }
    );
    return toLinkResult(payload, request.action);
  } finally {
    isOpen = false;
  }
}

/** The action as the native module takes it, or a `TypeError`. */
function checkedAction(value: unknown): NativeLinkAction {
  if (!isRecord(value)) {
    throw new TypeError("openLink: pass an action such as { action: 'add' } or { action: 'network', chargerId }");
  }
  if (typeof value.action !== 'string' || value.action.trim() === '') {
    throw new TypeError('openLink: action.action must be a non-empty string');
  }
  for (const key of ['chargerId', 'siteId'] as const) {
    const id = value[key];
    if (id !== undefined && id !== null && typeof id !== 'string') {
      throw new TypeError(`openLink: action.${key} must be a string`);
    }
  }
  // Checked above, so there is an action.
  return toLinkAction(value) as NativeLinkAction;
}

const statuses: readonly LinkStatus[] = ['success', 'cancelled', 'error'];

/**
 * The native payload `{ status, action, sessionId?, devices, error?: { code, message? } }` as a
 * {@link LinkResult}: a missing `action` is the opened one, a missing `sessionId` is `null`,
 * `error` and `error.message` only appear when set.
 */
export function toLinkResult(payload: unknown, openedAction: string): LinkResult {
  if (!isRecord(payload) || !isStatus(payload.status)) {
    throw codedError('ERR_PLUGCHOICE_INTERNAL', 'The Plugchoice native module returned an unexpected result.');
  }
  const result: LinkResult = {
    status: payload.status,
    action: typeof payload.action === 'string' && payload.action !== '' ? payload.action : openedAction,
    sessionId: typeof payload.sessionId === 'string' && payload.sessionId !== '' ? payload.sessionId : null,
    devices: Array.isArray(payload.devices)
      ? payload.devices.filter(isDevice).map(({ type, id }) => ({ type, id }))
      : [],
  };
  const error = toLinkError(payload.error);
  if (error) {
    result.error = error;
  }
  return result;
}

function isDevice(value: unknown): value is Device {
  return isRecord(value) && typeof value.type === 'string' && typeof value.id === 'string';
}

function toLinkError(value: unknown): LinkError | undefined {
  if (!isRecord(value) || typeof value.code !== 'string') {
    return undefined;
  }
  const error: LinkError = { code: value.code };
  if (typeof value.message === 'string') {
    error.message = value.message;
  }
  return error;
}

function isStatus(value: unknown): value is LinkStatus {
  return statuses.some((status) => status === value);
}

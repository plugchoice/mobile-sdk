import PlugchoiceModule, { CLIENT_SECRET_REQUEST, type PlugchoiceNativeModule } from './PlugchoiceModule';
import { isRecord, toLinkAction } from './shared';
import type { PlugchoiceConfig } from './types';

let config: PlugchoiceConfig | undefined;
let subscription: { remove(): void } | undefined;

/**
 * Sets the callback the SDK fetches client secrets through (and the debug `hostOverride`). Call it
 * once, before {@link openLink}, for example when your app starts; a later call replaces both.
 *
 * Throws a `TypeError` when `fetchClientSecret` isn't a function or `hostOverride` isn't a string.
 * Where the native module isn't built in (web, Expo Go) it still stores them, and `openLink`
 * rejects with `ERR_PLUGCHOICE_UNAVAILABLE`.
 */
export function configurePlugchoice(options: PlugchoiceConfig): void {
  if (!isRecord(options) || typeof options.fetchClientSecret !== 'function') {
    throw new TypeError('configurePlugchoice: fetchClientSecret must be a function');
  }
  const { fetchClientSecret } = options;
  const hostOverride: unknown = options.hostOverride;
  if (hostOverride !== undefined && typeof hostOverride !== 'string') {
    throw new TypeError('configurePlugchoice: hostOverride must be a string');
  }
  config = hostOverride === undefined ? { fetchClientSecret } : { fetchClientSecret, hostOverride };

  const native = PlugchoiceModule;
  if (native && !subscription) {
    subscription = native.addListener(CLIENT_SECRET_REQUEST, (event) => {
      void answerClientSecretRequest(native, event);
    });
  }
}

/** What {@link configurePlugchoice} set, if it was called. */
export function currentConfig(): PlugchoiceConfig | undefined {
  return config;
}

/**
 * Answers one `onClientSecretRequest { requestId, action }` from the native SDK: calls
 * `fetchClientSecret` with the action Link opened with and hands the secret back, or tells the
 * native side it failed (the page then gets `clientSecretUnavailable`). Never throws.
 *
 * The secret only goes to the native module. A rejection's message stays here: it could carry
 * anything your networking put in it, so only the error's name crosses over.
 */
async function answerClientSecretRequest(native: PlugchoiceNativeModule, event: unknown): Promise<void> {
  if (!isRecord(event) || typeof event.requestId !== 'string') {
    return;
  }
  const { requestId } = event;
  const fetchClientSecret = config?.fetchClientSecret;
  if (!fetchClientSecret) {
    reply(native, requestId, { error: 'configurePlugchoice was not called' });
    return;
  }
  const action = toLinkAction(event.action);
  if (!action) {
    reply(native, requestId, { error: 'the request carried no action' });
    return;
  }

  let secret: unknown;
  try {
    secret = await fetchClientSecret(action);
  } catch (error) {
    reply(native, requestId, { error: `fetchClientSecret threw ${errorName(error)}` });
    return;
  }
  if (typeof secret !== 'string' || secret.trim() === '') {
    reply(native, requestId, { error: 'fetchClientSecret resolved without a client secret' });
    return;
  }
  reply(native, requestId, { secret });
}

function reply(native: PlugchoiceNativeModule, requestId: string, answer: { secret: string } | { error: string }) {
  try {
    if ('secret' in answer) {
      native.provideClientSecret(requestId, answer.secret);
    } else {
      native.rejectClientSecret(requestId, answer.error);
    }
  } catch {
    // The native side refused the answer; it gives up on the request by itself (30 s).
  }
}

function errorName(error: unknown): string {
  if (error instanceof Error) {
    return error.name;
  }
  return error === null ? 'null' : typeof error;
}

import { vi } from 'vitest';

import { CLIENT_SECRET_REQUEST, type PlugchoiceNativeModule } from '../src/PlugchoiceModule';

export type ClientSecretAnswer = { secret: string } | { error: string };

/**
 * A stand-in for the native module, with the native side of the client-secret bridge: the SDK
 * sends `onClientSecretRequest { requestId, action }` and waits for `provideClientSecret` or
 * `rejectClientSecret` with that id.
 */
export function createFakeNative() {
  const listeners = new Set<(event: unknown) => void>();
  const waiting = new Map<string, (answer: ClientSecretAnswer) => void>();
  let nextRequest = 0;

  const module = {
    openLink: vi.fn<PlugchoiceNativeModule['openLink']>(),
    provideClientSecret: vi.fn<PlugchoiceNativeModule['provideClientSecret']>((requestId, secret) => {
      waiting.get(requestId)?.({ secret });
      waiting.delete(requestId);
    }),
    rejectClientSecret: vi.fn<PlugchoiceNativeModule['rejectClientSecret']>((requestId, message) => {
      waiting.get(requestId)?.({ error: message });
      waiting.delete(requestId);
    }),
    getTransports: vi.fn<PlugchoiceNativeModule['getTransports']>(),
    addListener: vi.fn<PlugchoiceNativeModule['addListener']>((eventName, listener) => {
      if (eventName !== CLIENT_SECRET_REQUEST) throw new Error(`unexpected event ${eventName}`);
      listeners.add(listener);
      return { remove: () => listeners.delete(listener) };
    }),
  } satisfies PlugchoiceNativeModule;

  /** Sends any event body, as the native module would. */
  function emit(event: unknown) {
    for (const listener of listeners) listener(event);
  }

  /** What the native SDK does when it needs a secret for `action`: asks, and waits for the answer. */
  function requestClientSecret(action: unknown): Promise<ClientSecretAnswer> {
    const requestId = `request-${++nextRequest}`;
    return new Promise((resolve) => {
      waiting.set(requestId, resolve);
      emit({ requestId, action });
    });
  }

  return { module, emit, requestClientSecret, listeners };
}

export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** Lets pending promise callbacks run. */
export function settle() {
  return new Promise<void>((resolve) => setTimeout(resolve, 0));
}

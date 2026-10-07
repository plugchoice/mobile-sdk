import { requireOptionalNativeModule } from 'expo';

/** The action as JavaScript hands it to the native module: empty ids left out. */
export type NativeLinkAction = {
  action: string;
  chargerId?: string;
  siteId?: string;
};

export type NativeOpenLinkOptions = {
  hostOverride?: string;
};

/** The event the native module sends when the SDK needs a client secret. */
export const CLIENT_SECRET_REQUEST = 'onClientSecretRequest';

export type PlugchoiceNativeModule = {
  /**
   * Resolves with `{ status, action, sessionId?, devices: [{ type, id }], error?: { code,
   * message? } }` once the Link screen is gone; rejects with `ERR_LINK_ALREADY_OPEN` or
   * `ERR_LINK_CANNOT_PRESENT`.
   */
  openLink(action: NativeLinkAction, options: NativeOpenLinkOptions): Promise<unknown>;
  /** Answers the `onClientSecretRequest` with `requestId`. Unknown ids are ignored. */
  provideClientSecret(requestId: string, clientSecret: string): void;
  /** Fails the `onClientSecretRequest` with `requestId`: the page gets `clientSecretUnavailable`. */
  rejectClientSecret(requestId: string, message: string): void;
  /** `Plugchoice.transports()` on iOS, `Plugchoice.transports(context)` on Android. */
  getTransports(): Promise<unknown>;
  /**
   * `onClientSecretRequest` events: `{ requestId, action: { action, chargerId?, siteId? } }`, the
   * action Link opened with. Each one waits for `provideClientSecret` or `rejectClientSecret`
   * (the SDK gives up after 30 s).
   */
  addListener(eventName: typeof CLIENT_SECRET_REQUEST, listener: (event: unknown) => void): { remove(): void };
};

/**
 * The native module (ios/PlugchoiceModule.swift, android/src/main), or `null` where it isn't built
 * in: web, Expo Go, or an app that wasn't rebuilt after installing the package.
 */
export default requireOptionalNativeModule<PlugchoiceNativeModule>('Plugchoice');

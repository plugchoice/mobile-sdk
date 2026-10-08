/**
 * What Link opens for: an action, and the charger or site it is about. The SDK passes it to the
 * hosted page without reading it, so an action the page learns later works before this package
 * names it.
 */
export type LinkAction = {
  /** `add`, `setup`, `reconnect` (which also changes a charger's network), or a later one. */
  action: 'add' | 'setup' | 'reconnect' | (string & {});
  /** The charger. Every action but `add` needs one. */
  chargerId?: string;
  /** `add` only: the site to add the charger to. */
  siteId?: string;
};

export type PlugchoiceConfig = {
  /**
   * Returns a client secret (`cs_test_…` or `cs_live_…`) for `action`, which your server gets
   * from `POST /sdk/v1/client-sessions` with its own credentials, scoped to the action's charger
   * or site. Called when Link opens (while the page loads) and again, with the same action,
   * whenever the page's secret has expired. Rejecting, resolving with an empty string or taking
   * longer than 30 s shows the page's error screen with "Try again".
   */
  fetchClientSecret: (action: LinkAction) => Promise<string>;
  /**
   * Debug builds of your app only: `scheme://host[:port]` of a hosted UI to load instead of
   * `https://connect.plugchoice.com`, for example `http://192.168.1.20:5173`. Ignored, with a log
   * line, in release builds and when it isn't of that form.
   */
  hostOverride?: string;
};

/** How a Link run ended. */
export type LinkStatus = 'success' | 'cancelled' | 'error';

/** A device a Link run finished. */
export type Device = {
  /** An open string: `charger` today. Ignore types you don't know. */
  type: string;
  /** The device's Plugchoice id. */
  id: string;
};

/** Why a Link run ended in `error`. */
export type LinkError = {
  /**
   * One of the SDK's own codes: `clientSecretUnavailable` (your `fetchClientSecret` gave no
   * secret), `pageLoadFailed` (the page didn't load and the user left the "Try again" screen) or
   * `internal` (Android: no usable WebView). Otherwise a problem code from the page, such as
   * `not-found`.
   */
  code: string;
  /** Free text for logs. */
  message?: string;
};

/**
 * The outcome of a Link run, as the native SDKs report it.
 *
 * A convenience for your app's UI: your server confirms it with
 * `GET /sdk/v1/link-sessions/{id}` before relying on it.
 */
export type LinkResult = {
  /**
   * From the page, or `cancelled` / `error` when the screen closed without it (the user left
   * before the page was ready, the page hung, the page didn't load).
   */
  status: LinkStatus;
  /** The action the run did: the page's, else the one Link opened with. */
  action: string;
  /** The run, when the page started one. */
  sessionId: string | null;
  /** The devices the page reported (on `success`, the ones the run finished). */
  devices: Device[];
  /** Set on `error` when the page or the SDK says why. */
  error?: LinkError;
};

/** The `code` of an error `openLink` or `getTransports` rejects with. */
export type PlugchoiceErrorCode =
  /** The native module isn't in this build: web, Expo Go, or an app not rebuilt since installing. */
  | 'ERR_PLUGCHOICE_UNAVAILABLE'
  /** `openLink` before `configurePlugchoice`. */
  | 'ERR_PLUGCHOICE_NOT_CONFIGURED'
  /** A Link screen is already open. */
  | 'ERR_LINK_ALREADY_OPEN'
  /** There is no screen to show Link from (for example, the app is in the background). */
  | 'ERR_LINK_CANNOT_PRESENT'
  /** The native module answered with something unexpected. */
  | 'ERR_PLUGCHOICE_INTERNAL';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { PlugchoiceNativeModule } from '../src/PlugchoiceModule';
import type { LinkAction } from '../src/types';
import { createFakeNative, deferred, settle } from './fakeNative';

// The native module `requireOptionalNativeModule('Plugchoice')` hands back (null: not built in).
const native = vi.hoisted(() => ({ module: null as PlugchoiceNativeModule | null }));

vi.mock('expo', () => ({
  requireOptionalNativeModule: (name: string) => (name === 'Plugchoice' ? native.module : null),
}));

/** Imports the package fresh, so it picks up `native.module` as it is now and has no state. */
async function load() {
  vi.resetModules();
  return import('../src');
}

describe('the client-secret bridge', () => {
  let fake: ReturnType<typeof createFakeNative>;

  beforeEach(() => {
    fake = createFakeNative();
    native.module = fake.module;
  });

  afterEach(() => {
    native.module = null;
  });

  it('listens for onClientSecretRequest once configured, and only once', async () => {
    const { configurePlugchoice } = await load();
    expect(fake.module.addListener).not.toHaveBeenCalled();

    configurePlugchoice({ fetchClientSecret: async () => 'cs_test_1' });
    configurePlugchoice({ fetchClientSecret: async () => 'cs_test_2' });

    expect(fake.module.addListener).toHaveBeenCalledTimes(1);
    expect(fake.module.addListener).toHaveBeenCalledWith('onClientSecretRequest', expect.any(Function));
  });

  it('answers a request with the secret fetchClientSecret gives for the request’s action', async () => {
    const fetchClientSecret = vi.fn(async (_action: LinkAction) => 'cs_test_123');
    const { configurePlugchoice } = await load();
    configurePlugchoice({ fetchClientSecret });

    const answer = await fake.requestClientSecret({ action: 'network', chargerId: 'ch_1' });

    expect(answer).toEqual({ secret: 'cs_test_123' });
    expect(fetchClientSecret).toHaveBeenCalledWith({ action: 'network', chargerId: 'ch_1' });
    expect(fake.module.provideClientSecret).toHaveBeenCalledWith('request-1', 'cs_test_123');
    expect(fake.module.rejectClientSecret).not.toHaveBeenCalled();
  });

  it('gives fetchClientSecret only action, chargerId and siteId, without empty ids', async () => {
    const fetchClientSecret = vi.fn(async (_action: LinkAction) => 'cs_test_123');
    const { configurePlugchoice } = await load();
    configurePlugchoice({ fetchClientSecret });

    await fake.requestClientSecret({ action: 'add', siteId: 'site_1', chargerId: '', extra: 'x' });

    expect(fetchClientSecret).toHaveBeenCalledWith({ action: 'add', siteId: 'site_1' });
    expect(Object.keys(fetchClientSecret.mock.calls[0]?.[0] ?? {})).toEqual(['action', 'siteId']);
  });

  it('runs fetchClientSecret again for every request (a refresh), with the same action', async () => {
    let issued = 0;
    const fetchClientSecret = vi.fn(async (_action: LinkAction) => `cs_test_${++issued}`);
    const { configurePlugchoice } = await load();
    configurePlugchoice({ fetchClientSecret });

    const action = { action: 'reconnect', chargerId: 'ch_1' };
    expect(await fake.requestClientSecret(action)).toEqual({ secret: 'cs_test_1' });
    expect(await fake.requestClientSecret(action)).toEqual({ secret: 'cs_test_2' });

    expect(fetchClientSecret).toHaveBeenCalledTimes(2);
    expect(fetchClientSecret).toHaveBeenNthCalledWith(2, { action: 'reconnect', chargerId: 'ch_1' });
  });

  it('answers each request by its id, in whatever order the secrets arrive', async () => {
    const first = deferred<string>();
    const second = deferred<string>();
    const fetchClientSecret = vi
      .fn<(action: LinkAction) => Promise<string>>()
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    const { configurePlugchoice } = await load();
    configurePlugchoice({ fetchClientSecret });

    const firstAnswer = fake.requestClientSecret({ action: 'add' });
    const secondAnswer = fake.requestClientSecret({ action: 'add' });
    second.resolve('cs_test_second');
    await settle();
    first.resolve('cs_test_first');

    await expect(firstAnswer).resolves.toEqual({ secret: 'cs_test_first' });
    await expect(secondAnswer).resolves.toEqual({ secret: 'cs_test_second' });
    expect(fake.module.provideClientSecret.mock.calls).toEqual([
      ['request-2', 'cs_test_second'],
      ['request-1', 'cs_test_first'],
    ]);
  });

  it('rejects the request when fetchClientSecret rejects, without passing on the error’s message', async () => {
    const { configurePlugchoice } = await load();
    configurePlugchoice({
      fetchClientSecret: async () => {
        throw new TypeError('GET https://backend.example/secret?token=abc failed');
      },
    });

    const answer = await fake.requestClientSecret({ action: 'add' });

    expect(answer).toEqual({ error: 'fetchClientSecret threw TypeError' });
    expect(fake.module.provideClientSecret).not.toHaveBeenCalled();
  });

  it('rejects the request when fetchClientSecret throws before returning a promise', async () => {
    const { configurePlugchoice } = await load();
    configurePlugchoice({
      fetchClientSecret: () => {
        throw new Error('not signed in');
      },
    });

    await expect(fake.requestClientSecret({ action: 'add' })).resolves.toEqual({
      error: 'fetchClientSecret threw Error',
    });
  });

  it('rejects the request when fetchClientSecret rejects with something that is not an Error', async () => {
    const { configurePlugchoice } = await load();
    configurePlugchoice({ fetchClientSecret: () => Promise.reject('offline') });

    await expect(fake.requestClientSecret({ action: 'add' })).resolves.toEqual({
      error: 'fetchClientSecret threw string',
    });
  });

  it('rejects the request when fetchClientSecret resolves without a secret', async () => {
    const { configurePlugchoice } = await load();
    const results: unknown[] = ['', '   ', undefined, null, 42, { client_secret: 'cs_test_123' }];
    const fetchClientSecret = vi.fn<(action: LinkAction) => Promise<string>>();
    for (const result of results) fetchClientSecret.mockResolvedValueOnce(result as string);
    configurePlugchoice({ fetchClientSecret });

    for (const _ of results) {
      await expect(fake.requestClientSecret({ action: 'add' })).resolves.toEqual({
        error: 'fetchClientSecret resolved without a client secret',
      });
    }
    expect(fake.module.provideClientSecret).not.toHaveBeenCalled();
  });

  it('uses the callback of the latest configurePlugchoice', async () => {
    const { configurePlugchoice } = await load();
    configurePlugchoice({ fetchClientSecret: async () => 'cs_test_old' });
    configurePlugchoice({ fetchClientSecret: async () => 'cs_test_new' });

    await expect(fake.requestClientSecret({ action: 'add' })).resolves.toEqual({ secret: 'cs_test_new' });
  });

  it('rejects a request without an action, and ignores an event without a request id', async () => {
    const fetchClientSecret = vi.fn(async (_action: LinkAction) => 'cs_test_123');
    const { configurePlugchoice } = await load();
    configurePlugchoice({ fetchClientSecret });

    await expect(fake.requestClientSecret(undefined)).resolves.toEqual({ error: 'the request carried no action' });
    await expect(fake.requestClientSecret({ action: '' })).resolves.toEqual({ error: 'the request carried no action' });

    fake.emit({ action: { action: 'add' } });
    fake.emit('request-9');
    fake.emit(null);
    await settle();

    expect(fetchClientSecret).not.toHaveBeenCalled();
    expect(fake.module.provideClientSecret).not.toHaveBeenCalled();
    expect(fake.module.rejectClientSecret).toHaveBeenCalledTimes(2);
  });

  it('survives a native module that refuses the answer', async () => {
    const { configurePlugchoice } = await load();
    configurePlugchoice({ fetchClientSecret: async () => 'cs_test_123' });
    fake.module.provideClientSecret.mockImplementationOnce(() => {
      throw new Error('Unknown request');
    });
    const unhandled = vi.fn();
    process.on('unhandledRejection', unhandled);

    fake.emit({ requestId: 'request-gone', action: { action: 'add' } });
    await settle();

    process.off('unhandledRejection', unhandled);
    expect(fake.module.provideClientSecret).toHaveBeenCalledWith('request-gone', 'cs_test_123');
    expect(unhandled).not.toHaveBeenCalled();
  });

  it('does not listen where the native module is not built in', async () => {
    native.module = null;
    const { configurePlugchoice } = await load();

    configurePlugchoice({ fetchClientSecret: async () => 'cs_test_123' });

    expect(fake.module.addListener).not.toHaveBeenCalled();
  });

  it('gets a secret to the native SDK while Link is open, end to end', async () => {
    const fetchClientSecret = vi.fn(async (action: LinkAction) => `cs_test_for_${action.chargerId}`);
    // The native SDK: fetches the secret when the screen opens, and once more when the page's
    // secret has expired, then closes with the page's result.
    fake.module.openLink.mockImplementation(async (action) => {
      const answers = [await fake.requestClientSecret(action), await fake.requestClientSecret(action)];
      expect(answers).toEqual([{ secret: 'cs_test_for_ch_1' }, { secret: 'cs_test_for_ch_1' }]);
      return { status: 'success', action: action.action, sessionId: 'ls_1', devices: [{ type: 'charger', id: 'ch_1' }] };
    });
    const { configurePlugchoice, openLink } = await load();
    configurePlugchoice({ fetchClientSecret });

    const result = await openLink({ action: 'network', chargerId: 'ch_1' });

    expect(result).toEqual({
      status: 'success',
      action: 'network',
      sessionId: 'ls_1',
      devices: [{ type: 'charger', id: 'ch_1' }],
    });
    expect(fetchClientSecret.mock.calls).toEqual([
      [{ action: 'network', chargerId: 'ch_1' }],
      [{ action: 'network', chargerId: 'ch_1' }],
    ]);
  });

  it('lets the page report clientSecretUnavailable when the callback fails while Link is open', async () => {
    fake.module.openLink.mockImplementation(async (action) => {
      const answer = await fake.requestClientSecret(action);
      // What the native SDK does with a rejected request: the page shows its error screen, and
      // the user leaves it.
      return 'error' in answer
        ? { status: 'error', action: action.action, devices: [], error: { code: 'clientSecretUnavailable' } }
        : { status: 'success', action: action.action, sessionId: 'ls_1', devices: [] };
    });
    const { configurePlugchoice, openLink } = await load();
    configurePlugchoice({
      fetchClientSecret: async () => {
        throw new Error('503');
      },
    });

    await expect(openLink({ action: 'add' })).resolves.toEqual({
      status: 'error',
      action: 'add',
      sessionId: null,
      devices: [],
      error: { code: 'clientSecretUnavailable' },
    });
  });
});

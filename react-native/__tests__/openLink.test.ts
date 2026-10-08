import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { PlugchoiceNativeModule } from '../src/PlugchoiceModule';
import { createFakeNative, deferred } from './fakeNative';

// The native module `requireOptionalNativeModule('Plugchoice')` hands back (null: not built in).
const native = vi.hoisted(() => ({ module: null as PlugchoiceNativeModule | null }));

vi.mock('expo', () => ({
  requireOptionalNativeModule: (name: string) => (name === 'Plugchoice' ? native.module : null),
}));

const fetchClientSecret = async () => 'cs_test_123';

/** Imports the package fresh, so it picks up `native.module` as it is now and has no state. */
async function load() {
  vi.resetModules();
  return import('../src');
}

/** The package, configured with a callback. */
async function configured(options: { hostOverride?: string } = {}) {
  const plugchoice = await load();
  plugchoice.configurePlugchoice({ fetchClientSecret, ...options });
  return plugchoice;
}

describe('openLink', () => {
  let fake: ReturnType<typeof createFakeNative>;

  beforeEach(() => {
    fake = createFakeNative();
    native.module = fake.module;
  });

  afterEach(() => {
    native.module = null;
  });

  it('passes the action and no options by default', async () => {
    fake.module.openLink.mockResolvedValue({ status: 'cancelled', action: 'add', devices: [] });
    const { openLink } = await configured();

    await openLink({ action: 'add' });

    expect(fake.module.openLink).toHaveBeenCalledWith({ action: 'add' }, {});
  });

  it('passes chargerId and siteId, and leaves out empty or missing ids', async () => {
    fake.module.openLink.mockResolvedValue({ status: 'cancelled', action: 'reconnect', devices: [] });
    const { openLink } = await configured();

    await openLink({ action: 'reconnect', chargerId: 'ch_1' });
    expect(fake.module.openLink).toHaveBeenLastCalledWith({ action: 'reconnect', chargerId: 'ch_1' }, {});

    await openLink({ action: 'add', siteId: 'site_1', chargerId: '' });
    expect(fake.module.openLink).toHaveBeenLastCalledWith({ action: 'add', siteId: 'site_1' }, {});

    const untyped = openLink as (action: unknown) => Promise<unknown>;
    await untyped({ action: 'setup', chargerId: 'ch_2', siteId: null, extra: true });
    expect(fake.module.openLink).toHaveBeenLastCalledWith({ action: 'setup', chargerId: 'ch_2' }, {});
  });

  it('passes an action this package does not name', async () => {
    fake.module.openLink.mockResolvedValue({ status: 'cancelled', action: 'meter_swap', devices: [] });
    const { openLink } = await configured();

    await openLink({ action: 'meter_swap', chargerId: 'ch_1' });

    expect(fake.module.openLink).toHaveBeenCalledWith({ action: 'meter_swap', chargerId: 'ch_1' }, {});
  });

  it('passes the configured hostOverride', async () => {
    fake.module.openLink.mockResolvedValue({ status: 'cancelled', action: 'add', devices: [] });
    const { openLink } = await configured({ hostOverride: 'http://192.168.1.20:5173' });

    await openLink({ action: 'add' });

    expect(fake.module.openLink).toHaveBeenCalledWith({ action: 'add' }, { hostOverride: 'http://192.168.1.20:5173' });
  });

  it('resolves with a success result as the native SDK reports it', async () => {
    fake.module.openLink.mockResolvedValue({
      status: 'success',
      action: 'add',
      sessionId: 'ls_1',
      devices: [
        { type: 'charger', id: 'ch_1' },
        { type: 'meter', id: 'm_1' },
      ],
    });
    const { openLink } = await configured();

    await expect(openLink({ action: 'add' })).resolves.toEqual({
      status: 'success',
      action: 'add',
      sessionId: 'ls_1',
      devices: [
        { type: 'charger', id: 'ch_1' },
        { type: 'meter', id: 'm_1' },
      ],
    });
  });

  it('fills in what the native SDK leaves out', async () => {
    // A screen that closed by itself: no sessionId; and an action the page didn't send.
    fake.module.openLink.mockResolvedValue({ status: 'cancelled', devices: [] });
    const { openLink } = await configured();

    await expect(openLink({ action: 'reconnect', chargerId: 'ch_1' })).resolves.toEqual({
      status: 'cancelled',
      action: 'reconnect',
      sessionId: null,
      devices: [],
    });
  });

  it('drops devices that are not { type, id } strings', async () => {
    fake.module.openLink.mockResolvedValue({
      status: 'success',
      action: 'add',
      sessionId: 'ls_1',
      devices: [{ type: 'charger', id: 'ch_1', name: 'Garage' }, { type: 'charger' }, { id: 42 }, 'ch_2', null],
    });
    const { openLink } = await configured();

    const result = await openLink({ action: 'add' });

    expect(result.devices).toEqual([{ type: 'charger', id: 'ch_1' }]);
  });

  it('leaves out error and error.message when the native SDK has none', async () => {
    fake.module.openLink.mockResolvedValue({
      status: 'error',
      action: 'add',
      sessionId: 'ls_1',
      devices: [],
      error: { code: 'clientSecretUnavailable' },
    });
    const { openLink } = await configured();

    const result = await openLink({ action: 'add' });
    expect(result.error).toEqual({ code: 'clientSecretUnavailable' });
    expect(Object.keys(result.error ?? {})).toEqual(['code']);

    fake.module.openLink.mockResolvedValue({ status: 'cancelled', action: 'add', sessionId: 'ls_1', devices: [] });
    expect('error' in (await openLink({ action: 'add' }))).toBe(false);
  });

  it('keeps the error message for logs', async () => {
    fake.module.openLink.mockResolvedValue({
      status: 'error',
      action: 'add',
      devices: [],
      error: { code: 'pageLoadFailed', message: 'The Internet connection appears to be offline.' },
    });
    const { openLink } = await configured();

    await expect(openLink({ action: 'add' })).resolves.toMatchObject({
      status: 'error',
      sessionId: null,
      error: { code: 'pageLoadFailed', message: 'The Internet connection appears to be offline.' },
    });
  });

  it('rejects a second call while a screen is open, and allows one after it closed', async () => {
    const first = deferred<unknown>();
    fake.module.openLink.mockReturnValueOnce(first.promise);
    const { openLink } = await configured();

    const firstCall = openLink({ action: 'add' });
    await expect(openLink({ action: 'reconnect', chargerId: 'ch_1' })).rejects.toMatchObject({
      code: 'ERR_LINK_ALREADY_OPEN',
    });
    expect(fake.module.openLink).toHaveBeenCalledTimes(1);

    first.resolve({ status: 'cancelled', action: 'add', devices: [] });
    await expect(firstCall).resolves.toMatchObject({ status: 'cancelled' });

    fake.module.openLink.mockResolvedValueOnce({
      status: 'success',
      action: 'reconnect',
      sessionId: 'ls_2',
      devices: [{ type: 'charger', id: 'ch_1' }],
    });
    await expect(openLink({ action: 'reconnect', chargerId: 'ch_1' })).resolves.toMatchObject({
      status: 'success',
      sessionId: 'ls_2',
    });
  });

  it('allows a new call after the native module rejected', async () => {
    fake.module.openLink.mockRejectedValueOnce(
      Object.assign(new Error('no view controller'), { code: 'ERR_LINK_CANNOT_PRESENT' })
    );
    const { openLink } = await configured();

    await expect(openLink({ action: 'add' })).rejects.toMatchObject({ code: 'ERR_LINK_CANNOT_PRESENT' });

    fake.module.openLink.mockResolvedValueOnce({ status: 'cancelled', action: 'add', devices: [] });
    await expect(openLink({ action: 'add' })).resolves.toMatchObject({ status: 'cancelled' });
  });

  it('passes on the native module rejecting a second screen', async () => {
    // The JavaScript side was reloaded while the native screen stayed open.
    fake.module.openLink.mockRejectedValueOnce(
      Object.assign(new Error('A Plugchoice Link screen is already open.'), { code: 'ERR_LINK_ALREADY_OPEN' })
    );
    const { openLink } = await configured();

    await expect(openLink({ action: 'add' })).rejects.toMatchObject({ code: 'ERR_LINK_ALREADY_OPEN' });
  });

  it('rejects before configurePlugchoice, without opening anything', async () => {
    const { openLink } = await load();

    await expect(openLink({ action: 'add' })).rejects.toMatchObject({
      code: 'ERR_PLUGCHOICE_NOT_CONFIGURED',
      message: expect.stringContaining('configurePlugchoice'),
    });
    expect(fake.module.openLink).not.toHaveBeenCalled();
  });

  it('rejects when the native module is not in the build', async () => {
    native.module = null;
    const { openLink } = await configured();

    await expect(openLink({ action: 'add' })).rejects.toMatchObject({ code: 'ERR_PLUGCHOICE_UNAVAILABLE' });
  });

  it('rejects arguments of the wrong type without opening anything', async () => {
    const { openLink } = await configured();
    const untyped = openLink as (action: unknown) => Promise<unknown>;

    for (const action of [
      'add',
      undefined,
      null,
      ['add'],
      {},
      { action: '' },
      { action: '  ' },
      { action: 42 },
      { action: 'reconnect', chargerId: 42 },
      { action: 'add', siteId: {} },
    ]) {
      await expect(untyped(action)).rejects.toBeInstanceOf(TypeError);
    }
    expect(fake.module.openLink).not.toHaveBeenCalled();
  });

  it('rejects a payload that is not a result', async () => {
    fake.module.openLink.mockResolvedValue({ status: 'done' });
    const { openLink } = await configured();

    await expect(openLink({ action: 'add' })).rejects.toMatchObject({ code: 'ERR_PLUGCHOICE_INTERNAL' });
  });
});

describe('configurePlugchoice', () => {
  beforeEach(() => {
    native.module = createFakeNative().module;
  });

  afterEach(() => {
    native.module = null;
  });

  it('rejects options of the wrong type', async () => {
    const { configurePlugchoice } = await load();
    const untyped = configurePlugchoice as (options: unknown) => void;

    expect(() => untyped(undefined)).toThrow(TypeError);
    expect(() => untyped({})).toThrow(/fetchClientSecret/);
    expect(() => untyped({ fetchClientSecret: 'cs_test_123' })).toThrow(/fetchClientSecret/);
    expect(() => untyped({ fetchClientSecret, hostOverride: 5173 })).toThrow(/hostOverride/);
  });

  it('works where the native module is not built in', async () => {
    native.module = null;
    const { configurePlugchoice } = await load();

    expect(() => configurePlugchoice({ fetchClientSecret })).not.toThrow();
  });
});

describe('getTransports', () => {
  afterEach(() => {
    native.module = null;
  });

  it('resolves with what the native SDK reports', async () => {
    const fake = createFakeNative();
    fake.module.getTransports.mockResolvedValue(['wifi', 'http', 'socket', 'lan', 'ble']);
    native.module = fake.module;
    const { getTransports } = await load();

    await expect(getTransports()).resolves.toEqual(['wifi', 'http', 'socket', 'lan', 'ble']);
  });

  it('needs no configurePlugchoice', async () => {
    const fake = createFakeNative();
    fake.module.getTransports.mockResolvedValue(['http', 'socket']);
    native.module = fake.module;
    const { getTransports } = await load();

    await expect(getTransports()).resolves.toEqual(['http', 'socket']);
  });

  it('drops anything that is not a string, and rejects what is not a list', async () => {
    const fake = createFakeNative();
    native.module = fake.module;
    const { getTransports } = await load();

    fake.module.getTransports.mockResolvedValue(['wifi', 7, null, 'ble']);
    await expect(getTransports()).resolves.toEqual(['wifi', 'ble']);

    fake.module.getTransports.mockResolvedValue({ wifi: true });
    await expect(getTransports()).rejects.toMatchObject({ code: 'ERR_PLUGCHOICE_INTERNAL' });
  });

  it('rejects when the native module is not in the build', async () => {
    const { getTransports } = await load();

    await expect(getTransports()).rejects.toMatchObject({ code: 'ERR_PLUGCHOICE_UNAVAILABLE' });
  });
});

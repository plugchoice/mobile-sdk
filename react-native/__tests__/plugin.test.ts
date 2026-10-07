import { createRequire } from 'node:module';

import type { ExpoConfig } from 'expo/config';
import type { AndroidConfig, ConfigPlugin, ExportedConfig, InfoPlist, ModConfig } from 'expo/config-plugins';
import { describe, expect, it, vi } from 'vitest';

// The plugin as an app's config loads it (app.plugin.js is CommonJS).
const require = createRequire(import.meta.url);

type Props = {
  cameraPermission?: string | false;
  locationWhenInUsePermission?: string | false;
  localNetworkPermission?: string;
  bluetoothPermission?: string | false;
  accessorySetupKit?: boolean;
  bonjourServices?: string[];
};
type Plugin = ConfigPlugin<Props | void> & {
  setInfoPlist(infoPlist: InfoPlist, props?: Props): InfoPlist;
  setEntitlements(entitlements: Record<string, unknown>): Record<string, unknown>;
  setMinSdkVersion(properties: AndroidConfig.Properties.PropertiesItem[]): AndroidConfig.Properties.PropertiesItem[];
  findBlockedPermissions(manifest: AndroidConfig.Manifest.AndroidManifest): string[];
};

const withPlugchoice: Plugin = require('../app.plugin.js');
// The same instance the plugin uses.
const { WarningAggregator }: typeof import('expo/config-plugins') = require('expo/config-plugins');
const { setInfoPlist, setEntitlements, setMinSdkVersion, findBlockedPermissions } = withPlugchoice;

const DEFAULT_CAMERA = 'Allow $(PRODUCT_NAME) to use the camera to scan the QR code on your charger.';
const DEFAULT_LOCATION =
  'Allow $(PRODUCT_NAME) to use your location to confirm it joined your charger’s Wi-Fi network.';
const DEFAULT_LOCAL_NETWORK = 'Allow $(PRODUCT_NAME) to connect to your charger on your local network.';
const DEFAULT_BLUETOOTH = 'Allow $(PRODUCT_NAME) to use Bluetooth to set up your charger.';
const DEFAULT_BONJOUR = ['_alfen._tcp', '_http._tcp', '_https._tcp'];

type ModAction<T> = (config: ExpoConfig & { modResults: T; modRequest: unknown }) => Promise<{ modResults: T }>;

/** Runs the mod the plugin registered for `platform`/`name` on `modResults`, like `expo prebuild`. */
async function runMod<T>(config: ExportedConfig, platform: keyof ModConfig, name: string, modResults: T): Promise<T> {
  const mods = config.mods?.[platform] as Record<string, ModAction<T>> | undefined;
  const mod = mods?.[name];
  if (!mod) throw new Error(`no ${platform}.${name} mod`);
  const result = await mod({
    ...config,
    modResults,
    modRequest: { platform, modName: name, projectRoot: '/app', platformProjectRoot: `/app/${platform}`, introspect: false },
  });
  return result.modResults;
}

function baseConfig(): ExpoConfig {
  return { name: 'Example', slug: 'example' };
}

describe('setInfoPlist', () => {
  it('adds the usage strings, AccessorySetupKit, Bonjour and local networking to an empty Info.plist', () => {
    expect(setInfoPlist({})).toEqual({
      NSCameraUsageDescription: DEFAULT_CAMERA,
      NSLocationWhenInUseUsageDescription: DEFAULT_LOCATION,
      NSLocalNetworkUsageDescription: DEFAULT_LOCAL_NETWORK,
      NSBluetoothAlwaysUsageDescription: DEFAULT_BLUETOOTH,
      NSAccessorySetupKitSupports: ['WiFi'],
      NSBonjourServices: DEFAULT_BONJOUR,
      NSAppTransportSecurity: { NSAllowsLocalNetworking: true },
    });
  });

  it('declares the default Bonjour services next to the app’s own, once', () => {
    const once = setInfoPlist({ NSBonjourServices: ['_http._tcp', '_myapp._udp.'] });
    expect(once.NSBonjourServices).toEqual(['_http._tcp', '_myapp._udp.', '_alfen._tcp', '_https._tcp']);
    expect(setInfoPlist(once).NSBonjourServices).toEqual(once.NSBonjourServices);
    // With or without the trailing dot, a type is declared once.
    expect(setInfoPlist({ NSBonjourServices: ['_alfen._tcp.'] }).NSBonjourServices).toEqual([
      '_alfen._tcp.',
      '_http._tcp',
      '_https._tcp',
    ]);
  });

  it('adds the bonjourServices option', () => {
    const infoPlist = setInfoPlist(
      { NSBonjourServices: ['_http._tcp'] },
      { bonjourServices: ['_lolo3._tcp', '_http._tcp', '_myapp._udp'] }
    );
    expect(infoPlist.NSBonjourServices).toEqual([
      '_http._tcp',
      '_alfen._tcp',
      '_https._tcp',
      '_lolo3._tcp',
      '_myapp._udp',
    ]);
  });

  it('rejects a bonjourServices option that is not a list of service types', () => {
    for (const bonjourServices of [['alfen'], ['_alfen._tcp', 42], '_alfen._tcp', ['_alfen._tcp.local.'], ['_a b._tcp']]) {
      expect(() => setInfoPlist({}, { bonjourServices } as unknown as Props)).toThrow(/bonjourServices/);
      expect(() => withPlugchoice(baseConfig(), { bonjourServices } as unknown as Props)).toThrow(/bonjourServices/);
    }
  });

  it('keeps usage strings the app already has', () => {
    const infoPlist = setInfoPlist({
      NSCameraUsageDescription: 'We scan codes.',
      NSLocationWhenInUseUsageDescription: 'We find chargers near you.',
      NSLocalNetworkUsageDescription: 'We talk to devices.',
      NSBluetoothAlwaysUsageDescription: 'We pair with your car.',
    });
    expect(infoPlist.NSCameraUsageDescription).toBe('We scan codes.');
    expect(infoPlist.NSLocationWhenInUseUsageDescription).toBe('We find chargers near you.');
    expect(infoPlist.NSLocalNetworkUsageDescription).toBe('We talk to devices.');
    expect(infoPlist.NSBluetoothAlwaysUsageDescription).toBe('We pair with your car.');
  });

  it('lets options override the usage strings', () => {
    const infoPlist = setInfoPlist(
      { NSCameraUsageDescription: 'Old.', NSBluetoothAlwaysUsageDescription: 'Old.' },
      {
        cameraPermission: 'Scan the code on your charger.',
        locationWhenInUsePermission: 'Check the charger network.',
        localNetworkPermission: 'Talk to your charger.',
        bluetoothPermission: 'Set up your charger over Bluetooth.',
      }
    );
    expect(infoPlist.NSCameraUsageDescription).toBe('Scan the code on your charger.');
    expect(infoPlist.NSLocationWhenInUseUsageDescription).toBe('Check the charger network.');
    expect(infoPlist.NSLocalNetworkUsageDescription).toBe('Talk to your charger.');
    expect(infoPlist.NSBluetoothAlwaysUsageDescription).toBe('Set up your charger over Bluetooth.');
  });

  it('leaves out the camera, location and Bluetooth strings and AccessorySetupKit when asked', () => {
    const infoPlist = setInfoPlist(
      {},
      {
        cameraPermission: false,
        locationWhenInUsePermission: false,
        bluetoothPermission: false,
        accessorySetupKit: false,
      }
    );
    expect(infoPlist).not.toHaveProperty('NSCameraUsageDescription');
    expect(infoPlist).not.toHaveProperty('NSLocationWhenInUseUsageDescription');
    expect(infoPlist).not.toHaveProperty('NSBluetoothAlwaysUsageDescription');
    expect(infoPlist).not.toHaveProperty('NSAccessorySetupKitSupports');
    expect(infoPlist.NSLocalNetworkUsageDescription).toBe(DEFAULT_LOCAL_NETWORK);
  });

  it('does not remove a string the app has when an option is false', () => {
    const infoPlist = setInfoPlist(
      { NSCameraUsageDescription: 'Ours.', NSBluetoothAlwaysUsageDescription: 'Ours too.' },
      { cameraPermission: false, bluetoothPermission: false }
    );
    expect(infoPlist.NSCameraUsageDescription).toBe('Ours.');
    expect(infoPlist.NSBluetoothAlwaysUsageDescription).toBe('Ours too.');
  });

  it('replaces an empty Bluetooth string with the default', () => {
    // iOS treats an empty usage description as none, and the SDK then leaves Bluetooth out.
    expect(setInfoPlist({ NSBluetoothAlwaysUsageDescription: '' }).NSBluetoothAlwaysUsageDescription).toBe(
      DEFAULT_BLUETOOTH
    );
  });

  it('adds WiFi next to other AccessorySetupKit kinds, once', () => {
    const once = setInfoPlist({ NSAccessorySetupKitSupports: ['Bluetooth'] });
    expect(once.NSAccessorySetupKitSupports).toEqual(['Bluetooth', 'WiFi']);
    expect(setInfoPlist(once).NSAccessorySetupKitSupports).toEqual(['Bluetooth', 'WiFi']);
  });

  it('merges NSAllowsLocalNetworking into existing ATS settings', () => {
    const infoPlist = setInfoPlist({
      NSAppTransportSecurity: { NSExceptionDomains: { 'example.com': { NSIncludesSubdomains: true } } },
    });
    expect(infoPlist.NSAppTransportSecurity).toEqual({
      NSExceptionDomains: { 'example.com': { NSIncludesSubdomains: true } },
      NSAllowsLocalNetworking: true,
    });
  });

  it('leaves ATS alone when the app allows arbitrary loads', () => {
    // NSAllowsLocalNetworking would make iOS ignore NSAllowsArbitraryLoads.
    const infoPlist = setInfoPlist({ NSAppTransportSecurity: { NSAllowsArbitraryLoads: true } });
    expect(infoPlist.NSAppTransportSecurity).toEqual({ NSAllowsArbitraryLoads: true });
  });

  it('is idempotent and does not touch other keys', () => {
    const input: InfoPlist = { CFBundleDisplayName: 'Example', UIBackgroundModes: ['fetch'] };
    const once = setInfoPlist(input, { cameraPermission: 'Scan.' });
    expect(setInfoPlist(once, { cameraPermission: 'Scan.' })).toEqual(once);
    expect(once.CFBundleDisplayName).toBe('Example');
    expect(once.UIBackgroundModes).toEqual(['fetch']);
    expect(input).toEqual({ CFBundleDisplayName: 'Example', UIBackgroundModes: ['fetch'] });
  });
});

describe('setEntitlements', () => {
  it('adds the hotspot and Wi-Fi info entitlements, keeping the others', () => {
    const entitlements = setEntitlements({ 'aps-environment': 'development' });
    expect(entitlements).toEqual({
      'aps-environment': 'development',
      'com.apple.developer.networking.HotspotConfiguration': true,
      'com.apple.developer.networking.wifi-info': true,
    });
    expect(setEntitlements(entitlements)).toEqual(entitlements);
  });
});

describe('setMinSdkVersion', () => {
  const property = (value: string): AndroidConfig.Properties.PropertiesItem => ({
    type: 'property',
    key: 'android.minSdkVersion',
    value,
  });

  it('adds android.minSdkVersion=29 when the app has none', () => {
    const properties = setMinSdkVersion([{ type: 'property', key: 'hermesEnabled', value: 'true' }]);
    expect(properties).toContainEqual(property('29'));
    expect(properties).toContainEqual({ type: 'property', key: 'hermesEnabled', value: 'true' });
    expect(setMinSdkVersion(properties)).toEqual(properties);
  });

  it('raises a lower minSdkVersion and keeps a higher one', () => {
    expect(setMinSdkVersion([property('24')])).toEqual([property('29')]);
    expect(setMinSdkVersion([property('31')])).toEqual([property('31')]);
  });
});

describe('findBlockedPermissions', () => {
  it('reports SDK permissions the app removes, and nothing else', () => {
    const manifest: AndroidConfig.Manifest.AndroidManifest = {
      manifest: {
        $: { 'xmlns:android': 'http://schemas.android.com/apk/res/android' },
        queries: [],
        'uses-permission': [
          { $: { 'android:name': 'android.permission.ACCESS_FINE_LOCATION', 'tools:node': 'remove' } },
          { $: { 'android:name': 'android.permission.RECORD_AUDIO', 'tools:node': 'remove' } },
          { $: { 'android:name': 'android.permission.INTERNET' } },
        ],
      },
    };
    expect(findBlockedPermissions(manifest)).toEqual(['android.permission.ACCESS_FINE_LOCATION']);
  });

  it('reports the Bluetooth permissions the app removes', () => {
    const manifest: AndroidConfig.Manifest.AndroidManifest = {
      manifest: {
        $: { 'xmlns:android': '' },
        queries: [],
        'uses-permission': [
          { $: { 'android:name': 'android.permission.BLUETOOTH_SCAN', 'tools:node': 'remove' } },
          { $: { 'android:name': 'android.permission.BLUETOOTH_CONNECT', 'tools:node': 'remove' } },
          { $: { 'android:name': 'android.permission.BLUETOOTH', 'tools:node': 'remove' } },
          { $: { 'android:name': 'android.permission.BLUETOOTH_ADMIN', 'tools:node': 'remove' } },
          { $: { 'android:name': 'android.permission.BLUETOOTH_ADVERTISE', 'tools:node': 'remove' } },
        ],
      },
    };
    expect(findBlockedPermissions(manifest)).toEqual([
      'android.permission.BLUETOOTH_SCAN',
      'android.permission.BLUETOOTH_CONNECT',
      'android.permission.BLUETOOTH',
      'android.permission.BLUETOOTH_ADMIN',
    ]);
  });

  it('handles a manifest without permissions', () => {
    expect(findBlockedPermissions({ manifest: { $: { 'xmlns:android': '' }, queries: [] } })).toEqual([]);
  });
});

describe('withPlugchoice', () => {
  it('registers the iOS Info.plist and entitlements mods and the Android manifest and gradle.properties mods', async () => {
    const config = withPlugchoice(baseConfig(), { cameraPermission: 'Scan the code.' });

    const infoPlist = await runMod<InfoPlist>(config, 'ios', 'infoPlist', { CFBundleName: 'Example' });
    expect(infoPlist).toMatchObject({
      CFBundleName: 'Example',
      NSCameraUsageDescription: 'Scan the code.',
      NSLocalNetworkUsageDescription: DEFAULT_LOCAL_NETWORK,
      NSBluetoothAlwaysUsageDescription: DEFAULT_BLUETOOTH,
      NSAccessorySetupKitSupports: ['WiFi'],
      NSBonjourServices: DEFAULT_BONJOUR,
    });

    const entitlements = await runMod<Record<string, unknown>>(config, 'ios', 'entitlements', {});
    expect(entitlements).toEqual({
      'com.apple.developer.networking.HotspotConfiguration': true,
      'com.apple.developer.networking.wifi-info': true,
    });

    const manifest: AndroidConfig.Manifest.AndroidManifest = { manifest: { $: { 'xmlns:android': '' }, queries: [] } };
    expect(await runMod(config, 'android', 'manifest', manifest)).toEqual(manifest);

    const gradleProperties = await runMod<AndroidConfig.Properties.PropertiesItem[]>(
      config,
      'android',
      'gradleProperties',
      [{ type: 'property', key: 'android.minSdkVersion', value: '24' }]
    );
    expect(gradleProperties).toEqual([{ type: 'property', key: 'android.minSdkVersion', value: '29' }]);
  });

  it('warns when the app blocks a permission the SDK needs', async () => {
    const warn = vi.spyOn(WarningAggregator, 'addWarningAndroid').mockImplementation(() => {});
    const config = withPlugchoice(baseConfig());
    await runMod<AndroidConfig.Manifest.AndroidManifest>(config, 'android', 'manifest', {
      manifest: {
        $: { 'xmlns:android': '' },
        queries: [],
        'uses-permission': [{ $: { 'android:name': 'android.permission.NEARBY_WIFI_DEVICES', 'tools:node': 'remove' } }],
      },
    });
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalledWith(
      '@plugchoice/react-native',
      expect.stringContaining('android.permission.NEARBY_WIFI_DEVICES')
    );
    warn.mockRestore();
  });

  it('warns, separately, when the app blocks the Bluetooth permissions', async () => {
    const warn = vi.spyOn(WarningAggregator, 'addWarningAndroid').mockImplementation(() => {});
    const config = withPlugchoice(baseConfig());
    await runMod<AndroidConfig.Manifest.AndroidManifest>(config, 'android', 'manifest', {
      manifest: {
        $: { 'xmlns:android': '' },
        queries: [],
        'uses-permission': [
          { $: { 'android:name': 'android.permission.BLUETOOTH_SCAN', 'tools:node': 'remove' } },
          { $: { 'android:name': 'android.permission.BLUETOOTH_CONNECT', 'tools:node': 'remove' } },
          { $: { 'android:name': 'android.permission.ACCESS_WIFI_STATE', 'tools:node': 'remove' } },
        ],
      },
    });
    expect(warn).toHaveBeenCalledTimes(2);
    expect(warn).toHaveBeenNthCalledWith(
      1,
      '@plugchoice/react-native',
      expect.stringMatching(/^The app removes android\.permission\.ACCESS_WIFI_STATE, which/)
    );
    expect(warn).toHaveBeenNthCalledWith(
      2,
      '@plugchoice/react-native',
      expect.stringMatching(
        /^The app removes android\.permission\.BLUETOOTH_SCAN, android\.permission\.BLUETOOTH_CONNECT, so .* can't use Bluetooth/
      )
    );
    warn.mockRestore();
  });

  it('warns when the app blocks the multicast permission mDNS discovery needs', () => {
    expect(
      findBlockedPermissions({
        manifest: {
          $: { 'xmlns:android': '' },
          queries: [],
          'uses-permission': [
            { $: { 'android:name': 'android.permission.CHANGE_WIFI_MULTICAST_STATE', 'tools:node': 'remove' } },
          ],
        },
      })
    ).toEqual(['android.permission.CHANGE_WIFI_MULTICAST_STATE']);
  });

  it('works without options', async () => {
    const config = withPlugchoice(baseConfig());
    const infoPlist = await runMod<InfoPlist>(config, 'ios', 'infoPlist', {});
    expect(infoPlist.NSCameraUsageDescription).toBe(DEFAULT_CAMERA);
    expect(infoPlist.NSBluetoothAlwaysUsageDescription).toBe(DEFAULT_BLUETOOTH);
  });

  it('runs once when an app lists it twice', async () => {
    const config = withPlugchoice(withPlugchoice(baseConfig()));
    const infoPlist = await runMod<InfoPlist>(config, 'ios', 'infoPlist', { NSAccessorySetupKitSupports: [] });
    expect(infoPlist.NSAccessorySetupKitSupports).toEqual(['WiFi']);
  });
});

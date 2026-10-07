// @ts-check
// Plain CommonJS (type-checked through JSDoc), so the plugin runs as installed: no build step.
const {
  WarningAggregator,
  createRunOncePlugin,
  withAndroidManifest,
  withEntitlementsPlist,
  withGradleProperties,
  withInfoPlist,
} = require('expo/config-plugins');

const pkg = require('../package.json');

/**
 * @typedef {object} PlugchoicePluginProps
 * @property {string | false} [cameraPermission] iOS `NSCameraUsageDescription`, for scanning the
 *   QR code on a charger's setup card. `false` leaves it out: the page then offers typing only.
 * @property {string | false} [locationWhenInUsePermission] iOS
 *   `NSLocationWhenInUseUsageDescription`, asked for before joining the charger's Wi-Fi so its
 *   network name can be read. `false` leaves it out.
 * @property {string} [localNetworkPermission] iOS `NSLocalNetworkUsageDescription`, for talking
 *   to the charger on its own network.
 * @property {string | false} [bluetoothPermission] iOS `NSBluetoothAlwaysUsageDescription`, for
 *   setting up chargers over Bluetooth. `false` leaves it out: the SDK then doesn't use Bluetooth
 *   (no `ble` in `getTransports()`), and App Store Connect may ask for it anyway, since the SDK
 *   links CoreBluetooth.
 * @property {boolean} [accessorySetupKit] Add `WiFi` to iOS `NSAccessorySetupKitSupports`, so iOS
 *   18+ joins the charger's Wi-Fi through AccessorySetupKit (one prompt per charger) instead of a
 *   "Join network?" prompt on every join. Default `true`.
 * @property {string[]} [bonjourServices] More DNS-SD service types for iOS `NSBonjourServices`,
 *   next to the default `_alfen._tcp`, `_http._tcp` and `_https._tcp` (iOS only browses declared
 *   types, so the page can only look for these).
 */

/** @typedef {import('expo/config-plugins').InfoPlist} InfoPlist */
/** @typedef {import('expo/config-plugins').AndroidConfig.Manifest.AndroidManifest} AndroidManifest */
/** @typedef {import('expo/config-plugins').AndroidConfig.Properties.PropertiesItem} PropertiesItem */

const DEFAULT_CAMERA_PERMISSION = 'Allow $(PRODUCT_NAME) to use the camera to scan the QR code on your charger.';
const DEFAULT_LOCATION_PERMISSION =
  'Allow $(PRODUCT_NAME) to use your location to confirm it joined your charger’s Wi-Fi network.';
const DEFAULT_LOCAL_NETWORK_PERMISSION = 'Allow $(PRODUCT_NAME) to connect to your charger on your local network.';
const DEFAULT_BLUETOOTH_PERMISSION = 'Allow $(PRODUCT_NAME) to use Bluetooth to set up your charger.';

/**
 * The DNS-SD service types the page may browse for (`lan.discover`) by default: iOS refuses to
 * browse a type the app doesn't declare in `NSBonjourServices`.
 */
const BONJOUR_SERVICES = ['_alfen._tcp', '_http._tcp', '_https._tcp'];
const BONJOUR_SERVICE_TYPE = /^_[A-Za-z0-9-]+\._(tcp|udp)\.?$/;

/** Joining a charger hotspot (NEHotspotConfiguration) and reading the current SSID. */
const ENTITLEMENTS = [
  'com.apple.developer.networking.HotspotConfiguration',
  'com.apple.developer.networking.wifi-info',
];

/** The Android library's minSdk (WifiNetworkSpecifier needs API 29). */
const ANDROID_MIN_SDK_VERSION = 29;
const MIN_SDK_PROPERTY = 'android.minSdkVersion';

/**
 * What the Android library uses. Its manifest already declares all of these, so the plugin adds
 * none; it only warns when the app removes one (`android.blockedPermissions`).
 */
const ANDROID_PERMISSIONS = [
  'android.permission.INTERNET',
  'android.permission.ACCESS_NETWORK_STATE',
  'android.permission.CHANGE_NETWORK_STATE',
  'android.permission.ACCESS_WIFI_STATE',
  'android.permission.CHANGE_WIFI_STATE',
  'android.permission.CHANGE_WIFI_MULTICAST_STATE',
  'android.permission.ACCESS_FINE_LOCATION',
  'android.permission.ACCESS_COARSE_LOCATION',
  'android.permission.NEARBY_WIFI_DEVICES',
];

/**
 * The library's Bluetooth permissions. An app may remove them on purpose: the SDK then leaves
 * Bluetooth out (no `ble` in `getTransports()`), so the plugin only says so.
 */
const ANDROID_BLUETOOTH_PERMISSIONS = [
  'android.permission.BLUETOOTH_SCAN',
  'android.permission.BLUETOOTH_CONNECT',
  'android.permission.BLUETOOTH',
  'android.permission.BLUETOOTH_ADMIN',
];

/**
 * The Info.plist keys the iOS SDK needs. An explicit option wins, then a value the app already
 * has, then the default. Idempotent.
 *
 * @param {InfoPlist} infoPlist
 * @param {PlugchoicePluginProps} props
 * @returns {InfoPlist}
 */
function setInfoPlist(infoPlist, props = {}) {
  const result = { ...infoPlist };
  setUsageDescription(result, 'NSCameraUsageDescription', props.cameraPermission, DEFAULT_CAMERA_PERMISSION);
  setUsageDescription(
    result,
    'NSLocationWhenInUseUsageDescription',
    props.locationWhenInUsePermission,
    DEFAULT_LOCATION_PERMISSION
  );
  setUsageDescription(
    result,
    'NSLocalNetworkUsageDescription',
    props.localNetworkPermission,
    DEFAULT_LOCAL_NETWORK_PERMISSION
  );
  setUsageDescription(
    result,
    'NSBluetoothAlwaysUsageDescription',
    props.bluetoothPermission,
    DEFAULT_BLUETOOTH_PERMISSION
  );

  if (props.accessorySetupKit !== false) {
    const supports = Array.isArray(result.NSAccessorySetupKitSupports) ? result.NSAccessorySetupKitSupports : [];
    if (!supports.includes('WiFi')) {
      result.NSAccessorySetupKitSupports = [...supports, 'WiFi'];
    }
  }

  // Finding devices on the home network by mDNS. Merged with the app's own entries; a type is the
  // same with or without its trailing dot.
  /** @type {Exclude<InfoPlist[string], undefined>[]} */
  const bonjour = Array.isArray(result.NSBonjourServices) ? [...result.NSBonjourServices] : [];
  const declared = new Set(bonjour.map((type) => (typeof type === 'string' ? type.replace(/\.$/, '') : type)));
  for (const type of [...BONJOUR_SERVICES, ...bonjourServicesOption(props.bonjourServices)]) {
    if (!declared.has(type.replace(/\.$/, ''))) {
      declared.add(type.replace(/\.$/, ''));
      bonjour.push(type);
    }
  }
  result.NSBonjourServices = bonjour;

  // Plain HTTP and WebSocket to the charger on the local network. Left alone when the app allows
  // arbitrary loads: on iOS 10+ adding NSAllowsLocalNetworking would switch that off.
  /** @type {Record<string, any>} */
  const ats = isPlainObject(result.NSAppTransportSecurity) ? result.NSAppTransportSecurity : {};
  if (ats.NSAllowsArbitraryLoads !== true && ats.NSAllowsLocalNetworking !== true) {
    result.NSAppTransportSecurity = { ...ats, NSAllowsLocalNetworking: true };
  }
  return result;
}

/**
 * The `bonjourServices` option, checked: service types such as `_http._tcp`.
 *
 * @param {unknown} option
 * @returns {string[]}
 */
function bonjourServicesOption(option) {
  if (option === undefined) return [];
  if (!Array.isArray(option) || !option.every((type) => typeof type === 'string' && BONJOUR_SERVICE_TYPE.test(type))) {
    throw new Error(
      `${pkg.name}: bonjourServices must be an array of DNS-SD service types such as "_http._tcp", got ${JSON.stringify(option)}`
    );
  }
  return option;
}

/**
 * @param {InfoPlist} infoPlist
 * @param {string} key
 * @param {string | false | undefined} option
 * @param {string} fallback
 */
function setUsageDescription(infoPlist, key, option, fallback) {
  if (option === false) return;
  if (typeof option === 'string') {
    infoPlist[key] = option;
  } else if (typeof infoPlist[key] !== 'string' || infoPlist[key] === '') {
    infoPlist[key] = fallback;
  }
}

/**
 * The entitlements the iOS SDK needs. Idempotent.
 *
 * @param {Record<string, any>} entitlements
 * @returns {Record<string, any>}
 */
function setEntitlements(entitlements) {
  const result = { ...entitlements };
  for (const key of ENTITLEMENTS) {
    result[key] = true;
  }
  return result;
}

/**
 * Raises `android.minSdkVersion` in gradle.properties (what Expo's Android build reads, and what
 * expo-build-properties writes) to the library's minimum. Never lowers it. Idempotent.
 *
 * @param {PropertiesItem[]} properties
 * @returns {PropertiesItem[]}
 */
function setMinSdkVersion(properties) {
  let found = false;
  const result = properties.map((item) => {
    if (item.type !== 'property' || item.key !== MIN_SDK_PROPERTY) return item;
    found = true;
    const current = Number.parseInt(item.value, 10);
    return current >= ANDROID_MIN_SDK_VERSION ? item : { ...item, value: String(ANDROID_MIN_SDK_VERSION) };
  });
  if (!found) {
    result.push(
      { type: 'comment', value: 'The Plugchoice SDK needs Android 10 (API 29) or later.' },
      { type: 'property', key: MIN_SDK_PROPERTY, value: String(ANDROID_MIN_SDK_VERSION) }
    );
  }
  return result;
}

/**
 * The SDK's permissions that the app's manifest removes (`tools:node="remove"`, which is what
 * Expo's `android.blockedPermissions` writes), Bluetooth ones included.
 *
 * @param {AndroidManifest} androidManifest
 * @returns {string[]}
 */
function findBlockedPermissions(androidManifest) {
  const permissions = androidManifest.manifest['uses-permission'] ?? [];
  return permissions
    .filter((permission) => permission.$['tools:node'] === 'remove')
    .map((permission) => permission.$['android:name'])
    .filter((name) => ANDROID_PERMISSIONS.includes(name) || ANDROID_BLUETOOTH_PERMISSIONS.includes(name));
}

/** @type {import('expo/config-plugins').ConfigPlugin<PlugchoicePluginProps | void>} */
const withPlugchoice = (config, props) => {
  const options = props ?? {};
  // Fail on a bad option when the app config loads, not halfway through prebuild.
  bonjourServicesOption(options.bonjourServices);

  config = withInfoPlist(config, (config) => {
    config.modResults = setInfoPlist(config.modResults, options);
    return config;
  });

  config = withEntitlementsPlist(config, (config) => {
    config.modResults = setEntitlements(config.modResults);
    return config;
  });

  config = withGradleProperties(config, (config) => {
    config.modResults = setMinSdkVersion(config.modResults);
    return config;
  });

  config = withAndroidManifest(config, (config) => {
    const blocked = findBlockedPermissions(config.modResults);
    const needed = blocked.filter((name) => ANDROID_PERMISSIONS.includes(name));
    const bluetooth = blocked.filter((name) => ANDROID_BLUETOOTH_PERMISSIONS.includes(name));
    if (needed.length > 0) {
      WarningAggregator.addWarningAndroid(
        pkg.name,
        `The app removes ${needed.join(', ')}, which the Plugchoice SDK needs to join a charger's Wi-Fi ` +
          `and talk to it. Remove ${needed.length === 1 ? 'it' : 'them'} from android.blockedPermissions.`
      );
    }
    if (bluetooth.length > 0) {
      WarningAggregator.addWarningAndroid(
        pkg.name,
        `The app removes ${bluetooth.join(', ')}, so the Plugchoice SDK can't use Bluetooth (Android 12 ` +
          `and later need BLUETOOTH_SCAN and BLUETOOTH_CONNECT, Android 10 and 11 BLUETOOTH and ` +
          `BLUETOOTH_ADMIN) and chargers set up over Bluetooth can't be set up there. If that isn't ` +
          `intended, remove ${bluetooth.length === 1 ? 'it' : 'them'} from android.blockedPermissions.`
      );
    }
    return config;
  });

  return config;
};

/**
 * @param {unknown} value
 * @returns {value is Record<string, any>}
 */
function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

module.exports = createRunOncePlugin(withPlugchoice, pkg.name, pkg.version);
module.exports.setInfoPlist = setInfoPlist;
module.exports.setEntitlements = setEntitlements;
module.exports.setMinSdkVersion = setMinSdkVersion;
module.exports.findBlockedPermissions = findBlockedPermissions;

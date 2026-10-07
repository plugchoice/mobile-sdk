import PlugchoiceModule from './PlugchoiceModule';
import { codedError } from './shared';

/**
 * What this device and app can do, without opening anything or asking for a permission: any of
 * `wifi` (joining a device's Wi-Fi), `http` (HTTP and WebSocket on the local network), `socket`
 * (raw TCP and UDP), `lan` (finding devices on the local network) and `ble` (Bluetooth LE).
 * Compare them with the `needs` of a charger's `capabilities` in the Plugchoice API before offering
 * an action.
 *
 * Rejects with `ERR_PLUGCHOICE_UNAVAILABLE` where the native module isn't built in (web, Expo Go).
 */
export async function getTransports(): Promise<string[]> {
  if (!PlugchoiceModule) {
    throw codedError(
      'ERR_PLUGCHOICE_UNAVAILABLE',
      'The Plugchoice native module is not in this build. It needs a development or release build of ' +
        'your app (not Expo Go or web), rebuilt after installing @plugchoice/react-native.'
    );
  }
  const transports = await PlugchoiceModule.getTransports();
  if (!Array.isArray(transports)) {
    throw codedError('ERR_PLUGCHOICE_INTERNAL', 'The Plugchoice native module returned unexpected transports.');
  }
  return transports.filter((transport): transport is string => typeof transport === 'string');
}

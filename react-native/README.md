# Plugchoice SDK for React Native

`@plugchoice/react-native`: the Plugchoice SDK for React Native and Expo apps, with a config plugin for the native setup.

```ts
import { configurePlugchoice, openLink } from '@plugchoice/react-native';

configurePlugchoice({ fetchClientSecret: (action) => yourBackend.plugchoiceClientSecret(action) });

const result = await openLink({ action: 'add' });
```

Follow the [React Native guide](https://developer.plugchoice.com/sdk/react-native) for the installation, the config plugin and your backend endpoint.

## Development

```sh
pnpm typecheck
pnpm test
pnpm pack    # the package, with the native SDKs copied in
```

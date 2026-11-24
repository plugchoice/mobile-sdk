# Security policy

## Reporting a vulnerability

Email security issues to [security@plugchoice.com](mailto:security@plugchoice.com). Please don't open a public GitHub issue for them.

Include what you can of:

- what the issue is and what an attacker could do with it;
- the steps to reproduce it, or a proof of concept;
- the SDK version and platform (iOS, Android or React Native), and the device and OS version;
- whether it involves the hosted flow on `connect.plugchoice.com` or the SDK API at `api.plugchoice.com/sdk/v1`.

Give us time to fix the issue before you share it with anyone else.

## Supported versions

The SDK is in beta (0.x). Security fixes go into the latest release only, so update to it.

## Dependencies

CI checks the SDK's dependencies for known advisories on every pull request and daily on main (`.github/workflows/audit.yml`). What an app gets from the SDK, the Android library's release runtime classpath and the React Native package's dependencies, fails at high or critical (CVSS 7 or more, or no score); the tooling for the SDK's own tests fails at critical only, and the Gradle plugins' own dependencies, which only run while building, are not checked. The Android library is checked with [osv-scanner](https://github.com/google/osv-scanner) on a Gradle lockfile written for the check, the React Native package with `pnpm audit`, and the Swift package has no dependencies. To run it locally from the repository root, with osv-scanner and jq installed:

```sh
(cd react-native && pnpm audit --prod --audit-level high && pnpm audit --audit-level critical)
.github/scripts/audit-android.sh
```

Fix an advisory by updating the dependency. When no fixed version can be used yet, add an exception with its reason and a date to look again: `[[IgnoredVulns]]` in `osv-scanner.toml`, or `auditConfig.ignoreGhsas` in `react-native/pnpm-workspace.yaml` with a comment.

## More

[Security](https://developer.plugchoice.com/sdk/security) in the documentation describes what the SDK and the hosted flow can do on a device, and how they're locked down.

// @ts-check
// Copies the native SDKs into this package, so the packed package builds on its own (a tarball
// holds only this folder and can't reach ../ios or ../android). Runs on `prepack`; the copies are
// gitignored (.gitignore), and `files` in package.json ships them.
//
//   ../ios/Sources/PlugchoiceSDK           -> ios/PlugchoiceSDK                   (pod PlugchoiceSDK)
//   ../android/plugchoice/build.gradle.kts -> android/plugchoice/build.gradle.kts (Gradle project :plugchoice-sdk)
//   ../android/plugchoice/src/main         -> android/plugchoice/src/main
const fs = require('node:fs');
const path = require('node:path');

const packageRoot = path.resolve(__dirname, '..');
const repositoryRoot = path.resolve(packageRoot, '..');

/** @type {Array<[string, string]>} */
const copies = [
  ['ios/Sources/PlugchoiceSDK', 'ios/PlugchoiceSDK'],
  ['android/plugchoice/build.gradle.kts', 'android/plugchoice/build.gradle.kts'],
  ['android/plugchoice/src/main', 'android/plugchoice/src/main'],
];

for (const [from] of copies) {
  const source = path.join(repositoryRoot, from);
  if (!fs.existsSync(source)) {
    throw new Error(`copy-native-sdk: ${source} is missing. Run this from a checkout of the whole repository.`);
  }
}

// Start clean so files deleted from the SDKs don't linger in the package.
fs.rmSync(path.join(packageRoot, 'ios/PlugchoiceSDK'), { recursive: true, force: true });
fs.rmSync(path.join(packageRoot, 'android/plugchoice'), { recursive: true, force: true });

for (const [from, to] of copies) {
  const destination = path.join(packageRoot, to);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.cpSync(path.join(repositoryRoot, from), destination, {
    recursive: true,
    filter: (file) => path.basename(file) !== '.DS_Store',
  });
  console.log(`copy-native-sdk: ${from} -> react-native/${to}`);
}

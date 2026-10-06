#!/bin/sh
# Run Firestore security-rules tests against the local emulator.
# Does not boot an iOS simulator and does not talk to the live Firebase project.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

java_ok() {
  java -version >/dev/null 2>&1
}

if ! java_ok; then
  for candidate in \
    /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
  do
    if [ -x "$candidate/bin/java" ]; then
      export JAVA_HOME="$candidate"
      export PATH="$JAVA_HOME/bin:$PATH"
      break
    fi
  done
fi

if ! java_ok; then
  echo "Java 21+ is required for the Firestore emulator." >&2
  echo "Install it with: brew install openjdk@21" >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to run the rules tests." >&2
  exit 1
fi

if [ ! -d node_modules/@firebase/rules-unit-testing ]; then
  npm install
fi

npm run test:rules

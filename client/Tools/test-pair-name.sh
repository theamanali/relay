#!/bin/sh
# Exercise the real HostConnection against fakehost without touching app state.
set -eu
cd "$(dirname "$0")/.."
PAIR_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/relay-pair-name.XXXXXX")
trap 'rm -rf "$PAIR_TEST_DIR"' EXIT HUP INT TERM
swiftc -O -o "$PAIR_TEST_DIR/fakehost" Tools/fakehost/main.swift \
    Sources/Relay/Noise.swift Sources/Relay/Field25519.swift Sources/Relay/CPace.swift \
    Sources/Relay/Protocol.swift Sources/Relay/VideoBitrate.swift
swiftc -O -o "$PAIR_TEST_DIR/check" Tools/pair-name-check/main.swift \
    Sources/Relay/Noise.swift Sources/Relay/Field25519.swift Sources/Relay/CPace.swift \
    Sources/Relay/Protocol.swift Sources/Relay/VideoBitrate.swift Sources/Relay/Crypto.swift \
    Sources/Relay/FrameReader.swift Sources/Relay/HostConnection.swift
mkdir "$PAIR_TEST_DIR/home"
CFFIXED_USER_HOME="$PAIR_TEST_DIR/home" "$PAIR_TEST_DIR/check" "$PAIR_TEST_DIR"

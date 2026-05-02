#!/bin/bash

docker run --rm --platform=linux/amd64 -e NETTY_DIR=/netty -v "$PWD:/netty" -v "$PWD/stage:/stage" -v "$HOME/.m2:/root/.m2" -w /netty --entrypoint /bin/sh alpine:edge -c 'apk add --no-cache --quiet bash >/dev/null 2>&1 && /netty/static-jni/scripts/stage-natives.sh /stage linux --prep-deps';

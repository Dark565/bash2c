#!/usr/bin/env bash

# -- RUN TESTS --

CC=${CC:-cc}

set -e

cd "$(dirname "$0")/tests"

on_error() {
	rm output.c a.out || true
	echo "Test failed"
	exit 1
}

trap on_error ERR

for i in *.sh; do
	../s2c.sh "$i" && ${CC} output.c && ./a.out
done

echo "All tests succeed"

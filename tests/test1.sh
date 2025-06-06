#!/bin/bash
echo Hello
ls | grep convert
for x in a b; do echo $x; done
if [ 1 -eq 1 ]; then echo OK; else echo BAD; fi
foo=$(whoami)
echo $foo
ls &


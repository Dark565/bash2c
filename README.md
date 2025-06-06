# s2c  Bash to C transpiler

## Purpose
This is a simple transpiler for a subset of Bash to C.  
It intends to output C code that is as self reliant as possible to minimize the need of running external commands.

## Usage
```sh
# Produce output.c
./s2c.sh script.sh

# Now you can compile your output.c
cc output.c

## This produces a.out. You can run it with:
./a.out
```

## Features
- Translate bash builting commands like test, \[ natively (without invoking external commands)
- Implement pipes natively
- Native support of arithmetic expression expansion such as $()

## Bugs
Many :)
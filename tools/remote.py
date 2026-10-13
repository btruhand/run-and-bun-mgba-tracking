#!/usr/bin/env python3
"""Send a Lua chunk to lua/dev/remote.lua running in mGBA and print what it logged.

    python3 tools/remote.py 'log(emu:currentFrame())'
    python3 tools/remote.py -f experiment.lua --timeout 120
"""
import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RDIR = os.path.join(ROOT, ".remote")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("code", nargs="?", help="Lua source to run")
    ap.add_argument("-f", "--file", help="read the Lua source from a file")
    ap.add_argument("--timeout", type=float, default=30, help="seconds to wait for the result")
    args = ap.parse_args()
    if args.file:
        with open(args.file) as f:
            src = f.read()
    elif args.code is not None:
        src = args.code
    else:
        src = sys.stdin.read()

    os.makedirs(RDIR, exist_ok=True)
    cmd = os.path.join(RDIR, "cmd.lua")
    if os.path.exists(cmd):
        sys.exit("a command is still waiting to be picked up (is remote.lua loaded and the game running?)")
    job = str(int(time.time() * 1000))
    tmp = cmd + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"--id={job}\n{src}\n")
    os.rename(tmp, cmd)

    out = os.path.join(RDIR, f"out-{job}.txt")
    deadline = time.time() + args.timeout
    while not os.path.exists(out):
        if time.time() > deadline:
            if os.path.exists(cmd):
                os.remove(cmd)
                sys.exit("timed out: the command was never picked up (is remote.lua loaded and the game unpaused?)")
            sys.exit("timed out: the command started but has not finished; its output will land in " + out)
        time.sleep(0.1)
    with open(out) as f:
        text = f.read()
    os.remove(out)
    sys.stdout.write(text)
    sys.exit(0 if text.rstrip().endswith("OK") else 1)


if __name__ == "__main__":
    main()

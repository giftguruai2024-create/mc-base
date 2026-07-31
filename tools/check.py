import sys, glob, os
from luaparser import ast

patterns = sys.argv[1:] or ["*.lua"]
files = []
for p in patterns:
    files.extend(glob.glob(p))
fail = 0
for f in sorted(files):
    with open(f, encoding="utf-8") as fh:
        src = fh.read()
    try:
        ast.parse(src)
        print(f"ok    {f}")
    except Exception as e:
        print(f"FAIL  {f}: {e}")
        fail = 1
sys.exit(fail)

#!/usr/bin/env python3
"""Static statistics of single-file C benchmarks (e.g. the CIL-merged Concrat programs), without running Goblint.

Usage: ./scripts/benchmark_stats.py file.c ... > stats.csv

Per file: lines of code (cloc, if installed), defined functions, whether there is a main function,
pthread_create call sites (how many are inside a loop, and the distinct start routines),
and the call sites of the lock and condition variable API.

The counts are syntactic and best-effort: a call site in a loop or in a wrapper function that is called
several times starts any number of threads, so the number of call sites is a lower bound on the number of
distinct threads (thread ids) only if every call site is reached at all. Loops are recognized as CIL prints
them (while, for, do). Start routines passed through variables or wrappers show as "?".
"""

import csv
import os
import re
import shutil
import subprocess
import sys

LOCK_APIS = {
    "mutex_lock": r"pthread_mutex_(?:lock|trylock|timedlock)",
    "rwlock": r"pthread_rwlock_(?:rdlock|wrlock|tryrdlock|trywrlock|timedrdlock|timedwrlock)",
    "spin_lock": r"pthread_spin_(?:lock|trylock)",
    "cond_wait": r"pthread_cond_(?:wait|timedwait)",
}


def strip_comments_and_strings(src):
    """Replaces comments and string/char literals by spaces, keeping offsets (and newlines) intact."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
        elif src.startswith("//", i) or (c == "#" and (i == 0 or src[i - 1] == "\n")):
            j = src.find("\n", i)
            j = n if j < 0 else j
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            j += 1
        else:
            i += 1
            continue
        for k in range(i, min(j, n)):
            if out[k] != "\n":
                out[k] = " "
        i = j
    return "".join(out)


def matching_paren(src, i):
    """Index of the parenthesis closing the one at i."""
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                return j
    return len(src)


def split_args(s):
    args, depth, start = [], 0, 0
    for j, c in enumerate(s):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            args.append(s[start:j])
            start = j + 1
    args.append(s[start:])
    return [a.strip() for a in args]


def start_routine(arg):
    """The function name in the start routine argument, e.g. (void *(*)(void * ))(& worker) -> worker."""
    arg = re.sub(r"\s+", " ", arg)
    m = re.fullmatch(r"(?:\([^()]*(?:\([^()]*\))*[^()]*\)\s*)*\(?\s*&?\s*([A-Za-z_]\w*)\s*\)?", arg)
    if m and m.group(1) not in ("NULL",):
        return m.group(1)
    return "?"


def analyze(path):
    with open(path, errors="replace") as f:
        raw = f.read()
    src = strip_comments_and_strings(raw)

    # Blocks: a stack of flags, whether the block (or an enclosing one) is a loop body;
    # and function definitions: a top-level block preceded by a parameter list.
    loop_at = {}  # offset of each call -> in loop, filled below
    calls = [m.start() for m in re.finditer(r"\bpthread_create\s*\(", src)]
    call_set = set(calls)
    stack = []
    functions = set()
    last_stmt_end = 0
    for i, c in enumerate(src):
        if i in call_set:
            loop_at[i] = any(stack)
        if c == "{":
            head = src[last_stmt_end:i]
            is_loop = bool(re.search(r"\b(?:while|for|do)\b", head))
            if not stack:
                m = re.search(r"([A-Za-z_]\w*)\s*\([^;{}]*\)\s*$", head)
                if m and not re.search(r"\b(?:struct|union|enum)\b\s*\w*\s*$", head):
                    functions.add(m.group(1))
            stack.append(is_loop or (bool(stack) and stack[-1]))
            last_stmt_end = i + 1
        elif c == "}":
            if stack:
                stack.pop()
            last_stmt_end = i + 1
        elif c == ";":
            last_stmt_end = i + 1

    creates, in_loop, routines = 0, 0, []
    for i in calls:
        # Declarations (prototypes) are at top level and followed by a parameter list with types, not a call.
        line_start = src.rfind("\n", 0, i) + 1
        prefix = src[line_start:i]
        if re.search(r"\b(?:extern|int)\s*$", prefix):
            continue
        creates += 1
        in_loop += bool(loop_at.get(i))
        j = src.index("(", i)
        args = split_args(src[j + 1:matching_paren(src, j)])
        routines.append(start_routine(args[2]) if len(args) >= 3 else "?")

    def count_calls(pattern):
        n = 0
        for m in re.finditer(r"\b(?:" + pattern + r")\s*\(", src):
            prefix = src[src.rfind("\n", 0, m.start()) + 1:m.start()]
            if not re.search(r"\b(?:extern|int)\s*$", prefix):
                n += 1
        return n

    loc = ""
    if shutil.which("cloc"):
        out = subprocess.run(["cloc", "--csv", "--quiet", path], capture_output=True, text=True).stdout
        rows = [r for r in out.strip().splitlines() if r and r[0].isdigit()]
        if rows:
            loc = rows[-1].split(",")[-1]

    stats = {
        "benchmark": os.path.splitext(os.path.basename(path))[0],
        "loc": loc,
        "functions": len(functions),
        "has_main": "main" in functions,
        "pthread_create": creates,
        "pthread_create_in_loop": in_loop,
        "start_routines": " ".join(sorted(set(routines))),
    }
    for name, pattern in LOCK_APIS.items():
        stats[name] = count_calls(pattern)
    return stats


def main():
    files = sys.argv[1:]
    if not files:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    rows = [analyze(f) for f in files]
    w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)


if __name__ == "__main__":
    main()

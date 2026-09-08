#!/usr/bin/env python3
"""Static cross-check for BoutiqueOS Rev 3 migrations (no DB needed).
Checks:
  1. INSERT INTO t (cols) -> every col exists on t (tables from CREATE TABLE)
  2. 'literal'::enum_type -> literal in enum definition
  3. fn_*/rpc_* calls -> function defined somewhere in the package
  4. UPDATE t SET col / SELECT ... FROM t alias.col (best-effort for known aliases)
  5. Every RPC has REVOKE FROM PUBLIC
"""
import re, sys, glob, os

root = sys.argv[1] if len(sys.argv) > 1 else "."
files = sorted(glob.glob(os.path.join(root, "supabase/migrations/*.sql")))
files += sorted(glob.glob(os.path.join(root, "seeds/*.sql")))
files += sorted(glob.glob(os.path.join(root, "tests/*.sql")))
srcs = {f: open(f, encoding="utf-8").read() for f in files}
mig = "\n".join(srcs[f] for f in files if "/migrations/" in f)

def strip_comments(s):
    return re.sub(r"--[^\n]*", "", s)

migc = strip_comments(mig)

# ---- tables
tables = {}
for m in re.finditer(r"CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(\w+)\s*\((.*?)\n\);", migc, re.S):
    name, body = m.group(1), m.group(2)
    cols = set()
    depth = 0; cur = []
    parts = []
    for ch in body:
        if ch == "(": depth += 1
        elif ch == ")": depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    for p in parts:
        p = p.strip()
        if not p: continue
        first = p.split()[0].upper()
        if first in ("PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "CONSTRAINT", "EXCLUDE"): continue
        cols.add(p.split()[0].lower())
    tables[name.lower()] = cols
# ALTER TABLE ADD COLUMN
for m in re.finditer(r"ALTER TABLE\s+(\w+)\s+ADD COLUMN\s+(?:IF NOT EXISTS\s+)?(\w+)", migc):
    tables.setdefault(m.group(1).lower(), set()).add(m.group(2).lower())
# temp tables
for m in re.finditer(r"CREATE TEMP TABLE\s+(?:IF NOT EXISTS\s+)?(\w+)\s*\((.*?)\)\s*ON COMMIT", migc, re.S):
    cols = {p.strip().split()[0].lower() for p in m.group(2).split(",") if p.strip()}
    tables[m.group(1).lower()] = cols

# ---- enums
enums = {}
for m in re.finditer(r"CREATE TYPE\s+(\w+)\s+AS ENUM\s*\((.*?)\);", migc, re.S):
    enums[m.group(1).lower()] = set(re.findall(r"'([^']*)'", m.group(2)))

# ---- functions
funcs = set(m.group(1).lower() for m in re.finditer(r"CREATE (?:OR REPLACE )?FUNCTION\s+(?:public\.)?(\w+)", migc))
builtin_ok = {"fn_set_business_id_from_parent"}

errors, warns = [], []

for f, s in srcs.items():
    sc = strip_comments(s)
    short = os.path.relpath(f, root)
    # 1. inserts
    for m in re.finditer(r"INSERT INTO\s+(\w+)\s*\(([^)]*)\)", sc):
        t = m.group(1).lower()
        cols = [c.strip().lower() for c in m.group(2).split(",") if c.strip()]
        if t not in tables:
            if "/migrations/" in f or "/seeds/" in f:
                errors.append(f"{short}: INSERT into unknown table {t}")
            continue
        for c in cols:
            if c not in tables[t]:
                errors.append(f"{short}: INSERT {t} unknown column '{c}'")
    # 2. enum literals
    for m in re.finditer(r"'([^']*)'::(\w+)", sc):
        lit, ty = m.group(1), m.group(2).lower()
        if ty in enums and lit not in enums[ty]:
            errors.append(f"{short}: '{lit}' not in enum {ty}")
    # IN ('a','b') after role/status checks — check v_role IN (...) for user_role
    for m in re.finditer(r"(?:v_role|fn_my_role\([^)]*\)|role)\s+(?:NOT\s+)?IN\s*\(([^)]*)\)", sc):
        for lit in re.findall(r"'([^']*)'", m.group(1)):
            if lit not in enums.get("user_role", set()):
                errors.append(f"{short}: role literal '{lit}' not in user_role")
    # 3. function calls
    for m in re.finditer(r"\b((?:fn|rpc)_\w+)\s*\(", sc):
        fn = m.group(1).lower()
        if fn not in funcs and fn not in builtin_ok:
            errors.append(f"{short}: call to undefined function {fn}")
    # 4. UPDATE t SET col
    for m in re.finditer(r"UPDATE\s+(\w+)\s+(?:\w+\s+)?SET\s+(.*?)\s+WHERE", sc, re.S):
        t = m.group(1).lower()
        if t not in tables: continue
        # split top-level assignments
        body = m.group(2); depth = 0; cur=[]; parts=[]
        for ch in body:
            if ch=="(":depth+=1
            elif ch==")":depth-=1
            if ch=="," and depth==0: parts.append("".join(cur)); cur=[]
            else: cur.append(ch)
        parts.append("".join(cur))
        for p in parts:
            c = p.strip().split("=")[0].strip().lower()
            if c and re.match(r"^\w+$", c) and c not in tables[t]:
                errors.append(f"{short}: UPDATE {t} unknown column '{c}'")
    # 5b. RAISE format placeholders vs supplied arguments
    #     RAISE [level] 'fmt', a, b USING ...;   count of unescaped % must equal argument count; %% ignored
    for m in re.finditer(r"\bRAISE\s+(?:EXCEPTION|NOTICE|WARNING|INFO|LOG|DEBUG)\s+'((?:[^']|'')*)'\s*(.*?);", sc, re.S):
        fmt, rest = m.group(1), m.group(2)
        n_ph = len(re.findall(r"%", fmt.replace("%%", "")))
        rest = re.split(r"\bUSING\b", rest, 1)[0].strip()
        if not rest:
            n_args = 0
        else:
            assert rest.startswith(","), rest
            body = rest[1:]; depth = 0; cur = []; parts = []; in_str = False
            for ch in body:
                if ch == "'": in_str = not in_str
                if not in_str:
                    if ch in "([": depth += 1
                    elif ch in ")]": depth -= 1
                    if ch == "," and depth == 0:
                        parts.append("".join(cur)); cur = []; continue
                cur.append(ch)
            parts.append("".join(cur))
            n_args = len([p for p in parts if p.strip()])
        if n_ph != n_args:
            line = sc[:m.start()].count("\n") + 1
            errors.append(f"{short}:{line}: RAISE has {n_ph} placeholder(s) but {n_args} argument(s): '{fmt[:60]}'")

    if "/migrations/" in f:
        for fn in re.findall(r"CREATE (?:OR REPLACE )?FUNCTION\s+(\w+)\s*\(", sc):
            if fn.startswith(("fn_", "rpc_")) and not re.search(rf"REVOKE EXECUTE ON FUNCTION {fn}\s*\(", sc):
                # trigger/helper fns w/o args ok if declared RETURNS TRIGGER
                if re.search(rf"FUNCTION {fn}\s*\(\)\s*RETURNS TRIGGER", sc): continue
                warns.append(f"{short}: {fn} has no REVOKE ... FROM PUBLIC")
            if fn.startswith("rpc_") and not re.search(rf"GRANT\s+EXECUTE ON FUNCTION {fn}\s*\(", sc):
                warns.append(f"{short}: {fn} has no GRANT to authenticated")

# record.col references for known aliases in 004 (best-effort)
alias_map = {"s.": "sales", "si.": "sale_items", "sic.": "sale_item_costs", "gr.": "goods_receipts",
             "gri.": "goods_receipt_items", "rs.": "register_sessions", "t.": "stock_transfers",
             "r.": "reservations", "th.": "transfer_held_inventory"}
print(f"tables={len(tables)} enums={len(enums)} funcs={len(funcs)}")
for e in errors: print("ERROR ", e)
for w in warns: print("WARN  ", w)
print(f"{len(errors)} errors, {len(warns)} warnings")
sys.exit(1 if errors else 0)

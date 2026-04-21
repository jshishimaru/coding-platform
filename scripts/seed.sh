#!/bin/bash

# ============================================================
# Database Seed Script for Coding Platform
# ============================================================
# Wipes any existing problems/contests/submissions/components and
# re-creates a small, complete demo dataset:
#
#   - 6 demo users (admin + 5 regular)
#   - 8 standard problems, each FULLY wired up with:
#       validator + checker + generator + AC solution + tests + tags
#     and published.
#   - 1 subjective problem (manually graded)
#   - 3 contests: past-global, upcoming-global, group-only proctored
#   - 1 group (CS101 Spring 2026) with members + a pending join request
#
# Users and groups are preserved across runs so you don't lose
# login credentials. Problems, contests, submissions and related
# data are wiped every run so the seed is fully reproducible.
#
# Prerequisites:
#   - Backend running on localhost:3000
#   - Postgres running in docker compose (service name: postgres)
#   - init.sql applied (schema exists)
#
# Usage:
#   chmod +x scripts/seed.sh
#   ./scripts/seed.sh
# ============================================================

set -euo pipefail

API="http://localhost:3000/api"
CONTENT_TYPE="Content-Type: application/json"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

success() { echo -e "${GREEN}✓${NC} $1"; }
info()    { echo -e "${CYAN}→${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
fail()    { echo -e "${RED}✗${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Coding Platform — Database Seed Script"
echo "═══════════════════════════════════════════════════"
echo ""

# ----------------------------------------------------------
# Health check
# ----------------------------------------------------------
info "Checking API health..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API/health" 2>/dev/null || true)
if [ "$HTTP_CODE" != "200" ]; then
  fail "Backend is not reachable at $API (HTTP $HTTP_CODE)."
  echo "  Make sure the server is running first."
  exit 1
fi
success "API is healthy"
echo ""

# ----------------------------------------------------------
# SQL helpers (run SQL inside the postgres container)
# ----------------------------------------------------------
# psql_query: returns first row, first column, trimmed.
psql_query() {
  docker compose exec -T postgres psql -U postgres -d coding_platform -tAq -c "$1" 2>/dev/null \
    | head -n 1 \
    | tr -d '[:space:]' \
    || echo ""
}
# psql_exec: fire-and-forget, swallow errors to not abort `set -e`.
psql_exec() {
  docker compose exec -T postgres psql -U postgres -d coding_platform -q -c "$1" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------
# 0. Destructive wipe
# ----------------------------------------------------------
# Wipe every table whose rows describe problems / contests / their
# components / submissions / grading / proctoring / generator runs.
# Everything else (users, groups, group_members, group_join_requests,
# tags) is preserved so seeded credentials don't rotate.
#
# We use TRUNCATE ... RESTART IDENTITY CASCADE so ids reset to 1 and
# dependent rows (which we've listed anyway) are dropped.
# ----------------------------------------------------------
echo "── Wiping existing problems, contests, submissions ───"

psql_exec "
  TRUNCATE
    app.submissions,
    app.contest_solves,
    app.contest_participants,
    app.contest_problems,
    app.contests,
    app.problem_tags,
    app.problem_access,
    app.problem_revisions,
    app.test_cases,
    app.generated_test_batches,
    app.problem_generators,
    app.problem_validators,
    app.problem_checkers,
    app.problem_interactors,
    app.problem_solutions,
    app.proctor_events,
    app.admin_audit_log,
    app.problems
  RESTART IDENTITY CASCADE;
"

# Sanity-check the wipe.
REMAINING_PROBLEMS=$(psql_query "SELECT COUNT(*) FROM app.problems;")
REMAINING_CONTESTS=$(psql_query "SELECT COUNT(*) FROM app.contests;")
if [ "$REMAINING_PROBLEMS" = "0" ] && [ "$REMAINING_CONTESTS" = "0" ]; then
  success "Wipe complete (problems=0, contests=0)"
else
  fail "Wipe did not empty tables (problems=$REMAINING_PROBLEMS, contests=$REMAINING_CONTESTS)"
  exit 1
fi
echo ""

# ----------------------------------------------------------
# 1. Register users (idempotent: register or log in)
# ----------------------------------------------------------
echo "── Creating Users ──────────────────────────────────"

declare -a TOKENS
declare -a USERNAMES=("admin" "alice" "bob" "charlie" "diana" "eve")
declare -a EMAILS=("admin@example.com" "alice@example.com" "bob@example.com" "charlie@example.com" "diana@example.com" "eve@example.com")
PASSWORD="password123"

for i in "${!USERNAMES[@]}"; do
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/auth/register" \
    -H "$CONTENT_TYPE" \
    -d "{
      \"username\": \"${USERNAMES[$i]}\",
      \"email\": \"${EMAILS[$i]}\",
      \"password\": \"$PASSWORD\"
    }" 2>/dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    TOKEN=$(echo "$BODY" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
    TOKENS[$i]="$TOKEN"
    success "Registered ${USERNAMES[$i]}"
  elif [ "$HTTP_CODE" = "409" ]; then
    LOGIN_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API/auth/login" \
      -H "$CONTENT_TYPE" \
      -d "{\"login\": \"${USERNAMES[$i]}\", \"password\": \"$PASSWORD\"}" 2>/dev/null)
    LOGIN_CODE=$(echo "$LOGIN_RESP" | tail -1)
    LOGIN_BODY=$(echo "$LOGIN_RESP" | sed '$d')
    if [ "$LOGIN_CODE" = "200" ]; then
      TOKEN=$(echo "$LOGIN_BODY" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
      TOKENS[$i]="$TOKEN"
      warn "${USERNAMES[$i]} already exists — logged in"
    else
      fail "Failed to log in as ${USERNAMES[$i]} (HTTP $LOGIN_CODE)"
      TOKENS[$i]=""
    fi
  else
    fail "Failed to register ${USERNAMES[$i]} (HTTP $HTTP_CODE)"
    TOKENS[$i]=""
  fi
done

# ----------------------------------------------------------
# 1b. Promote "admin" to admin role + re-login for admin JWT
# ----------------------------------------------------------
echo ""
echo "── Promoting admin user to admin role ────────────────"

psql_exec "UPDATE app.users SET role = 'admin' WHERE username = 'admin';"
success "Promoted 'admin' to role = 'admin' in database"

info "Re-logging in as admin to get admin-level token..."
LOGIN_RESP=$(curl -s -w "\n%{http_code}" -X POST "$API/auth/login" \
  -H "$CONTENT_TYPE" \
  -d '{"login": "admin", "password": "'"$PASSWORD"'"}' 2>/dev/null)
LOGIN_CODE=$(echo "$LOGIN_RESP" | tail -1)
LOGIN_BODY=$(echo "$LOGIN_RESP" | sed '$d')

if [ "$LOGIN_CODE" = "200" ]; then
  ADMIN_TOKEN=$(echo "$LOGIN_BODY" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
  ADMIN_ROLE=$(echo "$LOGIN_BODY" | grep -o '"role":"[^"]*"' | head -1 | cut -d'"' -f4)
  TOKENS[0]="$ADMIN_TOKEN"
  success "Admin re-login successful (role: $ADMIN_ROLE)"
else
  fail "Failed to re-login as admin (HTTP $LOGIN_CODE)"
  exit 1
fi
[ -z "$ADMIN_TOKEN" ] && { fail "No admin token. Aborting."; exit 1; }
echo ""

# ----------------------------------------------------------
# 2. Helpers for creating problems and their components
# ----------------------------------------------------------

# create_problem SLUG BODY_JSON  -> creates problem via REST, then makes
#                                    rev #1 active.
create_problem() {
  local SLUG="$1"
  local JSON="$2"

  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/questions" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "$JSON" 2>/dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" = "201" ]; then
    success "Created problem: $SLUG"
  else
    fail "Failed to create $SLUG (HTTP $HTTP_CODE): $BODY"
    return
  fi

  # Register rev #1 as active so the editor "Revisions" tab isn't empty.
  psql_exec "
    INSERT INTO app.problem_revisions
      (problem_id, revision, title, statement, difficulty, time_limit_ms,
       memory_limit_mb, checker_code, points, is_active, created_by)
    SELECT p.id, 1, p.title, p.statement, p.difficulty, p.time_limit_ms,
           p.memory_limit_mb, p.checker_code, p.points, TRUE, p.created_by
      FROM app.problems p
     WHERE p.slug = '$SLUG';
  "
}

# assign_tags SLUG TAG1 TAG2 ...
assign_tags() {
  local SLUG="$1"; shift
  local TAGS_JSON="["
  local FIRST=true
  for TAG in "$@"; do
    if [ "$FIRST" = true ]; then FIRST=false; else TAGS_JSON+=","; fi
    TAGS_JSON+="\"$TAG\""
  done
  TAGS_JSON+="]"

  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$API/questions/$SLUG/tags" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"tags\": $TAGS_JSON}" 2>/dev/null)
  if [ "$CODE" = "200" ]; then
    success "Tagged $SLUG"
  else
    warn "Failed to tag $SLUG (HTTP $CODE)"
  fi
}

# create_component PROBLEM_ID TYPE PAYLOAD LABEL
# TYPE is one of: validators, checkers, generators, solutions, interactors
create_component() {
  local PROBLEM_ID="$1"
  local COMPONENT_TYPE="$2"
  local PAYLOAD="$3"
  local LABEL="$4"

  [ -z "$PROBLEM_ID" ] && { warn "Skipping $LABEL — missing problem id"; return; }

  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/admin/problems/$PROBLEM_ID/$COMPONENT_TYPE" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "$PAYLOAD" 2>/dev/null)
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    success "$LABEL"
  else
    warn "Could not seed $LABEL (HTTP $CODE)"
  fi
}

# publish_problem PROBLEM_ID SLUG
publish_problem() {
  local PID="$1"
  local LABEL="$2"
  [ -z "$PID" ] && return
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/admin/problems/$PID/publish" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d '{}' 2>/dev/null)
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    success "Published $LABEL"
  else
    warn "Could not publish $LABEL (HTTP $CODE)"
  fi
}

# ----------------------------------------------------------
# Reusable C++ snippets (keep the JSON blobs below readable)
# ----------------------------------------------------------

# Exact-match checker: reads jury + contestant outputs line-wise, strips
# trailing whitespace (isspace covers \r too) on each line and trailing
# blank lines, then compares.
EXACT_CHECKER='#include <bits/stdc++.h>\nusing namespace std;\nstatic vector<string> trim_lines(istream&in){vector<string>v;string l;while(getline(in,l)){while(!l.empty()&&isspace((unsigned char)l.back()))l.pop_back();v.push_back(l);}while(!v.empty()&&v.back().empty())v.pop_back();return v;}\nint main(int argc,char**argv){if(argc<3)return 1;ifstream a(argv[1]),b(argv[2]);auto x=trim_lines(a),y=trim_lines(b);return x==y?0:1;}'

# Whitespace-insensitive checker: strips all whitespace and compares.
# Useful when multiple valid formats exist.
WS_CHECKER='#include <bits/stdc++.h>\nusing namespace std;\nstatic string squash(istream&in){string s,line;while(getline(in,line))s+=line;string t;for(char c:s)if(!isspace((unsigned char)c))t.push_back(c);return t;}\nint main(int argc,char**argv){if(argc<3)return 1;ifstream a(argv[1]),b(argv[2]);return squash(a)==squash(b)?0:1;}'

# ----------------------------------------------------------
# 3. Create 8 standard problems (skeletons only; components next)
# ----------------------------------------------------------
echo "── Creating Problems ─────────────────────────────────"

# ─── Problem 1: Two Sum ───
create_problem "two-sum" '{
  "title": "Two Sum",
  "slug": "two-sum",
  "difficulty": "easy",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Two Sum\n\nGiven an array of integers `nums` and an integer `target`, return the **indices** of the two numbers such that they add up to `target`.\n\nYou may assume that each input would have **exactly one solution**, and you may not use the same element twice.\n\nReturn the answer with the smaller index first.\n\n### Input Format\n- First line: two integers `n` and `target`\n- Second line: `n` space-separated integers\n\n### Output Format\n- Two space-separated integers: the 0-based indices\n\n### Constraints\n- 2 ≤ n ≤ 10^4\n- -10^9 ≤ nums[i] ≤ 10^9\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 4 9\\n2 7 11 15 | 0 1 |\n| 3 6\\n3 2 4 | 1 2 |",
  "checker_code": "",
  "test_cases": [
    {"input": "4 9\n2 7 11 15", "expected_output": "0 1", "is_sample": true},
    {"input": "3 6\n3 2 4",     "expected_output": "1 2", "is_sample": true},
    {"input": "2 6\n3 3",       "expected_output": "0 1", "is_sample": false},
    {"input": "5 -1\n-1 -2 -3 -4 -5", "expected_output": "0 4", "is_sample": false},
    {"input": "4 0\n-3 4 3 90", "expected_output": "0 2", "is_sample": false}
  ]
}'

# ─── Problem 2: Reverse String ───
create_problem "reverse-string" '{
  "title": "Reverse String",
  "slug": "reverse-string",
  "difficulty": "easy",
  "time_limit_ms": 1000,
  "memory_limit_mb": 256,
  "statement": "## Reverse String\n\nGiven a string `s`, reverse it and print the result.\n\n### Input Format\n- A single line containing the string `s`\n\n### Output Format\n- The reversed string\n\n### Constraints\n- 1 ≤ |s| ≤ 10^5\n- `s` consists of printable ASCII characters\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| hello | olleh |\n| OpenAI | IAnepO |",
  "checker_code": "",
  "test_cases": [
    {"input": "hello",    "expected_output": "olleh",   "is_sample": true},
    {"input": "OpenAI",   "expected_output": "IAnepO",  "is_sample": true},
    {"input": "a",        "expected_output": "a",       "is_sample": false},
    {"input": "racecar",  "expected_output": "racecar", "is_sample": false},
    {"input": "ab cd ef", "expected_output": "fe dc ba","is_sample": false}
  ]
}'

# ─── Problem 3: Valid Parentheses ───
create_problem "valid-parentheses" '{
  "title": "Valid Parentheses",
  "slug": "valid-parentheses",
  "difficulty": "easy",
  "time_limit_ms": 1000,
  "memory_limit_mb": 256,
  "statement": "## Valid Parentheses\n\nGiven a string `s` containing just the characters `(`, `)`, `{`, `}`, `[` and `]`, determine if the input string is valid.\n\nA string is valid if:\n1. Open brackets are closed by the same type of brackets.\n2. Open brackets are closed in the correct order.\n3. Every close bracket has a corresponding open bracket of the same type.\n\nPrint `YES` if valid, `NO` otherwise.\n\n### Input Format\n- A single line containing the string `s`\n\n### Output Format\n- `YES` or `NO`\n\n### Constraints\n- 1 ≤ |s| ≤ 10^4\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| () | YES |\n| ()[]{} | YES |\n| (] | NO |",
  "checker_code": "",
  "test_cases": [
    {"input": "()",       "expected_output": "YES", "is_sample": true},
    {"input": "()[]{}",   "expected_output": "YES", "is_sample": true},
    {"input": "(]",       "expected_output": "NO",  "is_sample": true},
    {"input": "((()))",   "expected_output": "YES", "is_sample": false},
    {"input": "{[()]}",   "expected_output": "YES", "is_sample": false},
    {"input": "(()",      "expected_output": "NO",  "is_sample": false},
    {"input": "}{",       "expected_output": "NO",  "is_sample": false}
  ]
}'

# ─── Problem 4: Fibonacci Number ───
create_problem "fibonacci-number" '{
  "title": "Fibonacci Number",
  "slug": "fibonacci-number",
  "difficulty": "medium",
  "time_limit_ms": 1000,
  "memory_limit_mb": 256,
  "statement": "## Fibonacci Number\n\nGiven an integer `n`, return the `n`-th Fibonacci number.\n\nThe Fibonacci sequence is defined as:\n- F(0) = 0\n- F(1) = 1\n- F(n) = F(n-1) + F(n-2) for n > 1\n\n### Input Format\n- A single integer `n`\n\n### Output Format\n- The `n`-th Fibonacci number\n\n### Constraints\n- 0 ≤ n ≤ 45\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 0 | 0 |\n| 1 | 1 |\n| 10 | 55 |",
  "checker_code": "",
  "test_cases": [
    {"input": "0",  "expected_output": "0",          "is_sample": true},
    {"input": "1",  "expected_output": "1",          "is_sample": true},
    {"input": "10", "expected_output": "55",         "is_sample": true},
    {"input": "20", "expected_output": "6765",       "is_sample": false},
    {"input": "45", "expected_output": "1134903170", "is_sample": false}
  ]
}'

# ─── Problem 5: Binary Search ───
create_problem "binary-search" '{
  "title": "Binary Search",
  "slug": "binary-search",
  "difficulty": "medium",
  "time_limit_ms": 1000,
  "memory_limit_mb": 256,
  "statement": "## Binary Search\n\nGiven a sorted array of integers `nums` and a target value `target`, return the index of `target` in the array. If `target` is not found, return `-1`.\n\n### Input Format\n- First line: two integers `n` and `target`\n- Second line: `n` sorted space-separated integers\n\n### Output Format\n- A single integer: the index (0-based) or `-1`\n\n### Constraints\n- 1 ≤ n ≤ 10^5\n- -10^9 ≤ nums[i], target ≤ 10^9\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 6 9\\n-1 0 3 5 9 12 | 4 |\n| 6 2\\n-1 0 3 5 9 12 | -1 |",
  "checker_code": "",
  "test_cases": [
    {"input": "6 9\n-1 0 3 5 9 12", "expected_output": "4",  "is_sample": true},
    {"input": "6 2\n-1 0 3 5 9 12", "expected_output": "-1", "is_sample": true},
    {"input": "1 5\n5",             "expected_output": "0",  "is_sample": false},
    {"input": "1 1\n5",             "expected_output": "-1", "is_sample": false},
    {"input": "5 3\n1 2 3 4 5",     "expected_output": "2",  "is_sample": false}
  ]
}'

# ─── Problem 6: Maximum Subarray ───
create_problem "maximum-subarray" '{
  "title": "Maximum Subarray",
  "slug": "maximum-subarray",
  "difficulty": "medium",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Maximum Subarray\n\nGiven an integer array `nums`, find the subarray with the largest sum, and return its sum.\n\n### Input Format\n- First line: integer `n`\n- Second line: `n` space-separated integers\n\n### Output Format\n- A single integer: the maximum subarray sum\n\n### Constraints\n- 1 ≤ n ≤ 10^5\n- -10^4 ≤ nums[i] ≤ 10^4\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 9\\n-2 1 -3 4 -1 2 1 -5 4 | 6 |\n| 1\\n1 | 1 |",
  "checker_code": "",
  "test_cases": [
    {"input": "9\n-2 1 -3 4 -1 2 1 -5 4", "expected_output": "6",  "is_sample": true},
    {"input": "1\n1",                     "expected_output": "1",  "is_sample": true},
    {"input": "5\n5 4 -1 7 8",            "expected_output": "23", "is_sample": false},
    {"input": "3\n-1 -2 -3",              "expected_output": "-1", "is_sample": false},
    {"input": "6\n1 -1 1 -1 1 -1",        "expected_output": "1",  "is_sample": false}
  ]
}'

# ─── Problem 7: Coin Change ───
create_problem "coin-change" '{
  "title": "Coin Change",
  "slug": "coin-change",
  "difficulty": "hard",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Coin Change\n\nYou are given an integer array `coins` representing coins of different denominations and an integer `amount` representing a total amount of money.\n\nReturn the **fewest number of coins** needed to make up that amount. If that amount cannot be made up, return `-1`.\n\nYou may assume you have an infinite number of each kind of coin.\n\n### Input Format\n- First line: two integers `n` and `amount`\n- Second line: `n` space-separated integers (coin denominations)\n\n### Output Format\n- A single integer\n\n### Constraints\n- 1 ≤ n ≤ 12\n- 1 ≤ coins[i] ≤ 2^31 - 1\n- 0 ≤ amount ≤ 10^4\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 3 11\\n1 5 2 | 3 |\n| 1 3\\n2 | -1 |\n| 1 0\\n1 | 0 |",
  "checker_code": "",
  "test_cases": [
    {"input": "3 11\n1 5 2", "expected_output": "3",  "is_sample": true},
    {"input": "1 3\n2",      "expected_output": "-1", "is_sample": true},
    {"input": "1 0\n1",      "expected_output": "0",  "is_sample": true},
    {"input": "3 6\n1 3 4",  "expected_output": "2",  "is_sample": false},
    {"input": "2 100\n1 50", "expected_output": "2",  "is_sample": false}
  ]
}'

# ─── Problem 8: N-Queens ───
create_problem "n-queens" '{
  "title": "N-Queens",
  "slug": "n-queens",
  "difficulty": "hard",
  "time_limit_ms": 3000,
  "memory_limit_mb": 256,
  "statement": "## N-Queens\n\nThe **N-Queens** puzzle is the problem of placing `n` queens on an `n x n` chessboard such that no two queens attack each other.\n\nGiven an integer `n`, return the **number** of distinct solutions to the N-Queens puzzle.\n\n### Input Format\n- A single integer `n`\n\n### Output Format\n- A single integer: the number of distinct solutions\n\n### Constraints\n- 1 ≤ n ≤ 12\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 4 | 2 |\n| 1 | 1 |\n| 8 | 92 |",
  "checker_code": "",
  "test_cases": [
    {"input": "4",  "expected_output": "2",     "is_sample": true},
    {"input": "1",  "expected_output": "1",     "is_sample": true},
    {"input": "8",  "expected_output": "92",    "is_sample": true},
    {"input": "5",  "expected_output": "10",    "is_sample": false},
    {"input": "9",  "expected_output": "352",   "is_sample": false},
    {"input": "12", "expected_output": "14200", "is_sample": false}
  ]
}'

echo ""

# ----------------------------------------------------------
# 4. Tag the problems
# ----------------------------------------------------------
echo "── Tagging Problems ──────────────────────────────────"

assign_tags "two-sum"            "Array" "Two Pointers" "Hash Table"
assign_tags "reverse-string"     "String" "Two Pointers"
assign_tags "valid-parentheses"  "String" "Stack"
assign_tags "fibonacci-number"   "Math" "Dynamic Programming" "Recursion"
assign_tags "binary-search"      "Array" "Binary Search"
assign_tags "maximum-subarray"   "Array" "Dynamic Programming" "Greedy"
assign_tags "coin-change"        "Array" "Dynamic Programming" "Greedy"
assign_tags "n-queens"           "Array" "Backtracking" "Recursion"

echo ""

# ----------------------------------------------------------
# 5. Fetch problem IDs
# ----------------------------------------------------------
echo "── Fetching Problem IDs ──────────────────────────────"

get_problem_id() { psql_query "SELECT id FROM app.problems WHERE slug = '$1' LIMIT 1;"; }

TWO_SUM_ID=$(get_problem_id       "two-sum")
REVERSE_STRING_ID=$(get_problem_id "reverse-string")
PARENTHESES_ID=$(get_problem_id   "valid-parentheses")
FIBONACCI_ID=$(get_problem_id     "fibonacci-number")
BINARY_SEARCH_ID=$(get_problem_id "binary-search")
MAX_SUBARRAY_ID=$(get_problem_id  "maximum-subarray")
COIN_CHANGE_ID=$(get_problem_id   "coin-change")
NQUEENS_ID=$(get_problem_id       "n-queens")

info "Fetched problem IDs"
echo ""

# ----------------------------------------------------------
# 6. Seed per-problem components (validator + checker + generator + AC)
# ----------------------------------------------------------
# Every standard problem gets the full stack so the admin editor
# ("Validators / Checkers / Generators / Solutions" tabs) is never
# empty for any seeded problem.
# ----------------------------------------------------------
echo "── Seeding Validators / Checkers / Generators / Solutions ──"

# =========================
# 1. TWO SUM
# =========================
create_component "$TWO_SUM_ID" "validators" "{
  \"name\": \"nums-range-validator\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; long long target; if(!(cin>>n>>target)) return 1; if(n<2||n>100000) return 1; for(int i=0;i<n;i++){ long long x; if(!(cin>>x)) return 1; if(x < -1000000000LL || x > 1000000000LL) return 1; } return 0;}\"
}" "two-sum validator"

create_component "$TWO_SUM_ID" "checkers" "{
  \"name\": \"exact-output-checker\",
  \"checker_type\": \"standard\",
  \"source_code\": \"$EXACT_CHECKER\"
}" "two-sum checker"

create_component "$TWO_SUM_ID" "generators" "{
  \"name\": \"random-nums\",
  \"description\": \"Random n in [2,20], random target.\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(int argc,char**argv){mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count());int n=uniform_int_distribution<int>(2,20)(rng);int target=uniform_int_distribution<int>(-50,50)(rng);cout<<n<<' '<<target<<\\\"\\\\n\\\";for(int i=0;i<n;i++){cout<<uniform_int_distribution<int>(-30,30)(rng);cout<<(i+1==n?'\\\\n':' ');}return 0;}\"
}" "two-sum generator"

create_component "$TWO_SUM_ID" "solutions" "{
  \"name\": \"two-sum-ac\",
  \"expected_verdict\": \"AC\",
  \"tag\": \"main\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; long long target; if(!(cin>>n>>target)) return 0; vector<long long>a(n); for(int i=0;i<n;i++)cin>>a[i]; unordered_map<long long,int> mp; for(int i=0;i<n;i++){ long long need=target-a[i]; if(mp.count(need)){ cout<<mp[need]<<\\\" \\\"<<i<<\\\"\\\\n\\\"; return 0; } mp[a[i]]=i; } return 0;}\"
}" "two-sum AC solution"

# =========================
# 2. REVERSE STRING
# =========================
create_component "$REVERSE_STRING_ID" "validators" "{
  \"name\": \"ascii-length-validator\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){string s; if(!getline(cin,s)) return 1; if(s.size()<1 || s.size()>100000) return 1; for(char c:s) if((unsigned char)c<32 || (unsigned char)c>126) return 1; return 0;}\"
}" "reverse-string validator"

create_component "$REVERSE_STRING_ID" "checkers" "{
  \"name\": \"exact-output-checker\",
  \"checker_type\": \"standard\",
  \"source_code\": \"$EXACT_CHECKER\"
}" "reverse-string checker"

create_component "$REVERSE_STRING_ID" "generators" "{
  \"name\": \"random-ascii\",
  \"description\": \"Random printable ASCII of length 1..30.\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count());int n=uniform_int_distribution<int>(1,30)(rng);for(int i=0;i<n;i++){int c=uniform_int_distribution<int>(33,126)(rng); putchar(c);} putchar('\\\\n'); return 0;}\"
}" "reverse-string generator"

create_component "$REVERSE_STRING_ID" "solutions" "{
  \"name\": \"reverse-ac\",
  \"expected_verdict\": \"AC\",
  \"tag\": \"main\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){string s; if(!getline(cin,s)) return 0; reverse(s.begin(),s.end()); cout<<s<<\\\"\\\\n\\\"; return 0;}\"
}" "reverse-string AC solution"

# =========================
# 3. VALID PARENTHESES
# =========================
create_component "$PARENTHESES_ID" "validators" "{
  \"name\": \"bracket-only-validator\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){string s; if(!getline(cin,s)) return 1; if(s.empty() || s.size()>10000) return 1; for(char c:s) if(c!='('&&c!=')'&&c!='['&&c!=']'&&c!='{'&&c!='}') return 1; return 0;}\"
}" "valid-parentheses validator"

create_component "$PARENTHESES_ID" "checkers" "{
  \"name\": \"exact-output-checker\",
  \"checker_type\": \"standard\",
  \"source_code\": \"$EXACT_CHECKER\"
}" "valid-parentheses checker"

create_component "$PARENTHESES_ID" "generators" "{
  \"name\": \"random-brackets\",
  \"description\": \"Random bracket string of length 2..20.\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count()); const char* b=\\\"()[]{}\\\"; int n=uniform_int_distribution<int>(2,20)(rng)&~1; for(int i=0;i<n;i++) putchar(b[uniform_int_distribution<int>(0,5)(rng)]); putchar('\\\\n'); return 0;}\"
}" "valid-parentheses generator"

create_component "$PARENTHESES_ID" "solutions" "{
  \"name\": \"valid-parens-ac\",
  \"expected_verdict\": \"AC\",
  \"tag\": \"main\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){string s; if(!getline(cin,s)) return 0; stack<char> st; for(char c:s){ if(c=='('||c=='['||c=='{') st.push(c); else { if(st.empty()){cout<<\\\"NO\\\\n\\\";return 0;} char t=st.top(); st.pop(); if((c==')'&&t!='(')||(c==']'&&t!='[')||(c=='}'&&t!='{')){cout<<\\\"NO\\\\n\\\";return 0;} } } cout<<(st.empty()?\\\"YES\\\":\\\"NO\\\")<<\\\"\\\\n\\\"; return 0;}\"
}" "valid-parentheses AC solution"

# =========================
# 4. FIBONACCI
# =========================
create_component "$FIBONACCI_ID" "validators" "{
  \"name\": \"n-range-validator\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){int n; if(!(cin>>n)) return 1; if(n<0||n>45) return 1; return 0;}\"
}" "fibonacci validator"

create_component "$FIBONACCI_ID" "checkers" "{
  \"name\": \"exact-output-checker\",
  \"checker_type\": \"standard\",
  \"source_code\": \"$EXACT_CHECKER\"
}" "fibonacci checker"

create_component "$FIBONACCI_ID" "generators" "{
  \"name\": \"small-random-n\",
  \"description\": \"Generates random n in [0,45]\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count()); cout<<uniform_int_distribution<int>(0,45)(rng)<<\\\"\\\\n\\\"; return 0;}\"
}" "fibonacci generator"

create_component "$FIBONACCI_ID" "solutions" "{
  \"name\": \"fibonacci-dp-ac\",
  \"expected_verdict\": \"AC\",
  \"tag\": \"main\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; if(!(cin>>n)) return 0; long long a=0,b=1; for(int i=0;i<n;i++){ long long c=a+b; a=b; b=c; } cout<<a<<\\\"\\\\n\\\"; return 0;}\"
}" "fibonacci AC solution"

# =========================
# 5. BINARY SEARCH
# =========================
create_component "$BINARY_SEARCH_ID" "validators" "{
  \"name\": \"sorted-input-validator\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){int n; long long t; if(!(cin>>n>>t)) return 1; if(n<1||n>100000) return 1; long long prev=LLONG_MIN; for(int i=0;i<n;i++){ long long x; if(!(cin>>x)) return 1; if(x<prev) return 1; prev=x; if(x<-1000000000LL||x>1000000000LL) return 1; } return 0;}\"
}" "binary-search validator"

create_component "$BINARY_SEARCH_ID" "checkers" "{
  \"name\": \"exact-output-checker\",
  \"checker_type\": \"standard\",
  \"source_code\": \"$EXACT_CHECKER\"
}" "binary-search checker"

create_component "$BINARY_SEARCH_ID" "generators" "{
  \"name\": \"sorted-random\",
  \"description\": \"Generates sorted arrays of length 1..30.\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count()); int n=uniform_int_distribution<int>(1,30)(rng); int t=uniform_int_distribution<int>(-50,50)(rng); cout<<n<<' '<<t<<\\\"\\\\n\\\"; vector<int>v(n); for(auto&x:v)x=uniform_int_distribution<int>(-50,50)(rng); sort(v.begin(),v.end()); for(int i=0;i<n;i++){cout<<v[i]; cout<<(i+1==n?'\\\\n':' ');} return 0;}\"
}" "binary-search generator"

create_component "$BINARY_SEARCH_ID" "solutions" "{
  \"name\": \"binary-search-ac\",
  \"expected_verdict\": \"AC\",
  \"tag\": \"main\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; long long t; if(!(cin>>n>>t)) return 0; vector<long long>a(n); for(int i=0;i<n;i++)cin>>a[i]; int lo=0,hi=n-1,ans=-1; while(lo<=hi){ int mid=(lo+hi)/2; if(a[mid]==t){ans=mid;break;} else if(a[mid]<t) lo=mid+1; else hi=mid-1; } cout<<ans<<\\\"\\\\n\\\"; return 0;}\"
}" "binary-search AC solution"

# =========================
# 6. MAXIMUM SUBARRAY
# =========================
create_component "$MAX_SUBARRAY_ID" "validators" "{
  \"name\": \"nums-range-validator\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){int n; if(!(cin>>n)) return 1; if(n<1||n>100000) return 1; for(int i=0;i<n;i++){ long long x; if(!(cin>>x)) return 1; if(x<-10000||x>10000) return 1; } return 0;}\"
}" "maximum-subarray validator"

# Intentionally uses the whitespace-insensitive checker to showcase
# "partial" checker_type.
create_component "$MAX_SUBARRAY_ID" "checkers" "{
  \"name\": \"whitespace-insensitive-checker\",
  \"checker_type\": \"partial\",
  \"source_code\": \"$WS_CHECKER\"
}" "maximum-subarray checker"

create_component "$MAX_SUBARRAY_ID" "generators" "{
  \"name\": \"random-small-array\",
  \"description\": \"Random int array of length 1..30, values in [-50,50].\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count()); int n=uniform_int_distribution<int>(1,30)(rng); cout<<n<<\\\"\\\\n\\\"; for(int i=0;i<n;i++){cout<<uniform_int_distribution<int>(-50,50)(rng); cout<<(i+1==n?'\\\\n':' ');} return 0;}\"
}" "maximum-subarray generator"

create_component "$MAX_SUBARRAY_ID" "solutions" "{
  \"name\": \"kadane-ac\",
  \"expected_verdict\": \"AC\",
  \"tag\": \"main\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; if(!(cin>>n)) return 0; long long best=LLONG_MIN,cur=0; for(int i=0;i<n;i++){ long long x; cin>>x; cur=max(x,cur+x); best=max(best,cur); } cout<<best<<\\\"\\\\n\\\"; return 0;}\"
}" "maximum-subarray AC solution"

# =========================
# 7. COIN CHANGE
# =========================
create_component "$COIN_CHANGE_ID" "validators" "{
  \"name\": \"coins-range-validator\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){int n; long long amt; if(!(cin>>n>>amt)) return 1; if(n<1||n>12) return 1; if(amt<0||amt>10000) return 1; for(int i=0;i<n;i++){ long long c; if(!(cin>>c)) return 1; if(c<1||c>2147483647LL) return 1; } return 0;}\"
}" "coin-change validator"

create_component "$COIN_CHANGE_ID" "checkers" "{
  \"name\": \"exact-output-checker\",
  \"checker_type\": \"standard\",
  \"source_code\": \"$EXACT_CHECKER\"
}" "coin-change checker"

create_component "$COIN_CHANGE_ID" "generators" "{
  \"name\": \"random-coins\",
  \"description\": \"n coins in [1,6], amount in [0,50].\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count()); int n=uniform_int_distribution<int>(1,6)(rng); int amt=uniform_int_distribution<int>(0,50)(rng); cout<<n<<' '<<amt<<\\\"\\\\n\\\"; for(int i=0;i<n;i++){cout<<uniform_int_distribution<int>(1,20)(rng); cout<<(i+1==n?'\\\\n':' ');} return 0;}\"
}" "coin-change generator"

create_component "$COIN_CHANGE_ID" "solutions" "{
  \"name\": \"coin-change-dp-ac\",
  \"expected_verdict\": \"AC\",
  \"tag\": \"main\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; long long amt; if(!(cin>>n>>amt)) return 0; vector<long long> coins(n); for(auto&c:coins)cin>>c; const long long INF=LLONG_MAX/2; vector<long long> dp(amt+1,INF); dp[0]=0; for(long long a=1;a<=amt;a++) for(auto c:coins) if(c<=a && dp[a-c]+1<dp[a]) dp[a]=dp[a-c]+1; cout<<(dp[amt]>=INF?-1:dp[amt])<<\\\"\\\\n\\\"; return 0;}\"
}" "coin-change AC solution"

# =========================
# 8. N-QUEENS
# =========================
create_component "$NQUEENS_ID" "validators" "{
  \"name\": \"n-range-validator\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){int n; if(!(cin>>n)) return 1; if(n<1||n>12) return 1; return 0;}\"
}" "n-queens validator"

create_component "$NQUEENS_ID" "checkers" "{
  \"name\": \"exact-output-checker\",
  \"checker_type\": \"standard\",
  \"source_code\": \"$EXACT_CHECKER\"
}" "n-queens checker"

create_component "$NQUEENS_ID" "generators" "{
  \"name\": \"random-n\",
  \"description\": \"Uniform n in [1,12].\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint main(){mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count()); cout<<uniform_int_distribution<int>(1,12)(rng)<<\\\"\\\\n\\\"; return 0;}\"
}" "n-queens generator"

create_component "$NQUEENS_ID" "solutions" "{
  \"name\": \"n-queens-ac\",
  \"expected_verdict\": \"AC\",
  \"tag\": \"main\",
  \"source_code\": \"#include <bits/stdc++.h>\\nusing namespace std;\\nint N; int cnt=0; vector<int> col; vector<bool> usedc,usedd,useda; void rec(int r){ if(r==N){cnt++;return;} for(int c=0;c<N;c++){ if(usedc[c]||usedd[r-c+N]||useda[r+c]) continue; usedc[c]=usedd[r-c+N]=useda[r+c]=true; rec(r+1); usedc[c]=usedd[r-c+N]=useda[r+c]=false; } }\\nint main(){ if(!(cin>>N)) return 0; usedc.assign(N,false); usedd.assign(2*N+1,false); useda.assign(2*N+1,false); rec(0); cout<<cnt<<\\\"\\\\n\\\"; return 0;}\"
}" "n-queens AC solution"

echo ""

# ----------------------------------------------------------
# 7. Publish the 8 standard problems
# ----------------------------------------------------------
echo "── Publishing Problems ───────────────────────────────"
publish_problem "$TWO_SUM_ID"       "two-sum"
publish_problem "$REVERSE_STRING_ID" "reverse-string"
publish_problem "$PARENTHESES_ID"   "valid-parentheses"
publish_problem "$FIBONACCI_ID"     "fibonacci-number"
publish_problem "$BINARY_SEARCH_ID" "binary-search"
publish_problem "$MAX_SUBARRAY_ID"  "maximum-subarray"
publish_problem "$COIN_CHANGE_ID"   "coin-change"
publish_problem "$NQUEENS_ID"       "n-queens"
echo ""

# ----------------------------------------------------------
# 8. Subjective problem (manual grading; used by group contest)
# ----------------------------------------------------------
echo "── Creating Subjective Problem ───────────────────────"

SUBJECTIVE_SLUG="essay-binary-search"
SUBJECTIVE_STATEMENT='## Design: Binary Search Variants\n\nImplement binary search in C++ and briefly explain (in comments) the invariant you maintain.\n\nYour submission will be **manually reviewed**. There are no automated test cases — focus on clarity, correctness of the invariant, and edge-case handling.\n\n### Deliverable\n- A complete, compilable C++ program that reads `n target` then `n` sorted integers and prints the index (0-based) or `-1`.\n- In comments at the top, state (1) your loop invariant and (2) why the loop terminates.'

SUBJECTIVE_ID=$(psql_query "INSERT INTO app.problems (title, slug, statement, difficulty, time_limit_ms, memory_limit_mb, problem_type, created_by, published_at)
   VALUES ('Binary Search: Design & Explain', '$SUBJECTIVE_SLUG', E'$SUBJECTIVE_STATEMENT', 'medium', 2000, 256, 'subjective',
           (SELECT id FROM app.users WHERE username='admin'), NOW())
   RETURNING id;")

if [ -n "$SUBJECTIVE_ID" ]; then
  success "Created subjective problem: $SUBJECTIVE_SLUG (id=$SUBJECTIVE_ID)"
  assign_tags "$SUBJECTIVE_SLUG" "Binary Search" "Array"
else
  fail "Failed to create subjective problem"
fi
echo ""

# ----------------------------------------------------------
# 9. Contests — 3 total
#    (a) past global, rated
#    (b) upcoming global, rated
#    (c) group-only proctored (created below after group exists)
# ----------------------------------------------------------
echo "── Creating Global Contests ──────────────────────────"

# (a) Past contest — ended
PAST_START="2026-02-20T10:00:00Z"
PAST_END="2026-02-20T12:00:00Z"

if [ -n "$TWO_SUM_ID" ] && [ -n "$REVERSE_STRING_ID" ] && [ -n "$PARENTHESES_ID" ]; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/contests" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{
      \"title\": \"Beginner Challenge #1\",
      \"description\": \"A friendly contest for newcomers. Easy problems to get you started!\",
      \"start_time\": \"$PAST_START\",
      \"end_time\": \"$PAST_END\",
      \"is_rated\": true,
      \"problems\": [
        {\"problem_id\": $TWO_SUM_ID,         \"points\": 100, \"problem_order\": 1},
        {\"problem_id\": $REVERSE_STRING_ID,  \"points\": 100, \"problem_order\": 2},
        {\"problem_id\": $PARENTHESES_ID,     \"points\": 150, \"problem_order\": 3}
      ]
    }" 2>/dev/null)
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    success "Created contest: Beginner Challenge #1 (ended)"
  else
    fail "Failed to create Beginner Challenge (HTTP $CODE)"
  fi
fi

# (b) Upcoming contest
FUTURE_START="2026-05-01T14:00:00Z"
FUTURE_END="2026-05-01T17:00:00Z"

if [ -n "$BINARY_SEARCH_ID" ] && [ -n "$MAX_SUBARRAY_ID" ] && [ -n "$COIN_CHANGE_ID" ] && [ -n "$NQUEENS_ID" ]; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/contests" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{
      \"title\": \"Intermediate Round #1\",
      \"description\": \"Step up your game! Medium and hard problems to test your algorithmic skills.\",
      \"start_time\": \"$FUTURE_START\",
      \"end_time\": \"$FUTURE_END\",
      \"is_rated\": true,
      \"problems\": [
        {\"problem_id\": $BINARY_SEARCH_ID, \"points\": 150, \"problem_order\": 1},
        {\"problem_id\": $MAX_SUBARRAY_ID,  \"points\": 200, \"problem_order\": 2},
        {\"problem_id\": $COIN_CHANGE_ID,   \"points\": 300, \"problem_order\": 3},
        {\"problem_id\": $NQUEENS_ID,       \"points\": 400, \"problem_order\": 4}
      ]
    }" 2>/dev/null)
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    success "Created contest: Intermediate Round #1 (upcoming)"
  else
    fail "Failed to create Intermediate Round (HTTP $CODE)"
  fi
fi
echo ""

# ----------------------------------------------------------
# 10. Group + members + pending join request
# ----------------------------------------------------------
echo "── Creating Group & Members ──────────────────────────"

ALICE_ID=$(psql_query   "SELECT id FROM app.users WHERE username='alice'   LIMIT 1;")
BOB_ID=$(psql_query     "SELECT id FROM app.users WHERE username='bob'     LIMIT 1;")
CHARLIE_ID=$(psql_query "SELECT id FROM app.users WHERE username='charlie' LIMIT 1;")
DIANA_ID=$(psql_query   "SELECT id FROM app.users WHERE username='diana'   LIMIT 1;")

GROUP_NAME="CS101 Spring 2026"
GROUP_ID=""

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/admin/groups" \
  -H "$CONTENT_TYPE" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d "{
    \"name\": \"$GROUP_NAME\",
    \"description\": \"Sample course group used to demonstrate group-only assignments, manual grading and proctoring.\",
    \"admin_user_ids\": [${CHARLIE_ID:-0}]
  }" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
  GROUP_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  success "Created group '$GROUP_NAME' (id=$GROUP_ID)"
elif [ "$HTTP_CODE" = "409" ]; then
  GROUP_ID=$(psql_query "SELECT id FROM app.groups WHERE name='$GROUP_NAME' LIMIT 1;")
  warn "Group already exists (id=$GROUP_ID) — reusing"
else
  fail "Failed to create group (HTTP $HTTP_CODE): $BODY"
fi

add_group_member() {
  local USER_ID="$1"
  local ROLE="$2"
  [ -z "$USER_ID" ] && return
  [ -z "$GROUP_ID" ] && return
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/admin/groups/$GROUP_ID/members" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"user_id\": $USER_ID, \"role\": \"$ROLE\"}" 2>/dev/null)
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    success "Added user #$USER_ID as $ROLE"
  else
    warn "Could not add user #$USER_ID (HTTP $CODE)"
  fi
}

if [ -n "$GROUP_ID" ]; then
  add_group_member "$ALICE_ID"   "member"
  add_group_member "$BOB_ID"     "member"
  [ -n "$CHARLIE_ID" ] && add_group_member "$CHARLIE_ID" "admin"

  # Pending join request from diana (for the approval-flow demo).
  if [ -n "$DIANA_ID" ]; then
    psql_exec "INSERT INTO app.group_join_requests (group_id, user_id, status, message)
       VALUES ($GROUP_ID, $DIANA_ID, 'pending', 'Hi! I''m a CS101 student — please add me.')
       ON CONFLICT DO NOTHING;"
    success "Created pending join request from diana"
  fi
fi
echo ""

# ----------------------------------------------------------
# 11. (c) Group-only proctored contest
# ----------------------------------------------------------
echo "── Creating Group Contest ────────────────────────────"

GROUP_CONTEST_START="2026-04-01T09:00:00Z"
GROUP_CONTEST_END="2026-04-01T12:00:00Z"

if [ -n "$GROUP_ID" ] && [ -n "$TWO_SUM_ID" ] && [ -n "$FIBONACCI_ID" ] && [ -n "$SUBJECTIVE_ID" ]; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/contests" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{
      \"title\": \"CS101 Assignment 1\",
      \"description\": \"Group-only assignment. Proctored. Mix of auto-graded and manually graded problems. Grades are visible to the whole group.\",
      \"start_time\": \"$GROUP_CONTEST_START\",
      \"end_time\": \"$GROUP_CONTEST_END\",
      \"is_rated\": false,
      \"group_id\": $GROUP_ID,
      \"proctored\": true,
      \"grade_visibility\": \"group\",
      \"problems\": [
        {\"problem_id\": $TWO_SUM_ID,     \"points\": 100, \"problem_order\": 1, \"scoring_mode\": \"partial\"},
        {\"problem_id\": $FIBONACCI_ID,   \"points\": 100, \"problem_order\": 2, \"scoring_mode\": \"partial\"},
        {\"problem_id\": $SUBJECTIVE_ID,  \"points\": 200, \"problem_order\": 3, \"scoring_mode\": \"all_or_nothing\"}
      ]
    }" 2>/dev/null)
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    success "Created group contest 'CS101 Assignment 1' (proctored, group-visible)"
  else
    fail "Failed to create group contest (HTTP $CODE)"
  fi
else
  warn "Skipping group contest — missing group or problem IDs"
fi
echo ""

# ----------------------------------------------------------
# 12. Summary
# ----------------------------------------------------------
echo "═══════════════════════════════════════════════════"
echo "  Seed Complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Users:     ${#USERNAMES[@]} (admin, alice, bob, charlie, diana, eve)"
echo "  Password:  $PASSWORD (for all users)"
echo "  Roles:     admin → site admin | others → user"
echo "  Problems:  9 (8 standard + 1 subjective)"
echo "             • each standard problem: validator + checker + generator + AC solution + tests + tags, published"
echo "  Contests:  3 (1 past global, 1 upcoming global, 1 group-only proctored)"
echo "  Groups:    1 (CS101 Spring 2026)"
echo "             • admin, charlie → group admins"
echo "             • alice, bob     → members"
echo "             • diana          → pending join request"
echo ""
echo "  Frontend:      http://localhost:8080 (any user)"
echo "  Admin Portal:  http://localhost:8081 (admin / $PASSWORD)"
echo "  DB Admin:      http://localhost:8082"
echo ""

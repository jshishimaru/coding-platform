#!/bin/bash

# ============================================================
# Database Seed Script for Coding Platform
# ============================================================
# Populates the database with sample users, problems (with test
# cases & tags), and contests via the REST API.
#
# Prerequisites:
#   - Backend server running on localhost:3000
#   - Database initialised (init.sql already applied)
#
# Usage:
#   chmod +x scripts/seed.sh
#   ./scripts/seed.sh
# ============================================================

set -euo pipefail

API="http://localhost:3000/api"
CONTENT_TYPE="Content-Type: application/json"

# Colours for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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
# 1. Register users
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
    # User already exists — log in instead
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
# 1b. Promote "admin" user to admin role via direct SQL
# ----------------------------------------------------------
echo ""
echo "── Promoting admin user to admin role ────────────────"

# Run SQL directly in the postgres container to set role = 'admin'
docker compose exec -T postgres psql -U postgres -d coding_platform -c \
  "UPDATE app.users SET role = 'admin' WHERE username = 'admin';" 2>/dev/null

if [ $? -eq 0 ]; then
  success "Promoted 'admin' to role = 'admin' in database"
else
  fail "Failed to promote admin user via SQL"
  exit 1
fi

# Re-login as admin to get a JWT with the updated 'admin' role
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

if [ -z "$ADMIN_TOKEN" ]; then
  fail "No admin token available. Cannot continue."
  exit 1
fi
echo ""

# ----------------------------------------------------------
# SQL helpers
# ----------------------------------------------------------
# Small helpers to run SQL inside the postgres container. They swallow errors
# so that set -euo pipefail doesn't abort the whole seed on transient issues.
#
# psql_query: returns the first line of output (the first RETURNING value or
# the first column of the first row), stripped of whitespace. Any trailing
# command tag like "INSERT 0 1" is discarded.
psql_query() {
  docker compose exec -T postgres psql -U postgres -d coding_platform -tAq -c "$1" 2>/dev/null \
    | head -n 1 \
    | tr -d '[:space:]' \
    || echo ""
}
psql_exec() {
  docker compose exec -T postgres psql -U postgres -d coding_platform -q -c "$1" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------
# 2. Create problems (questions with test cases)
# ----------------------------------------------------------
echo "── Creating Problems ─────────────────────────────────"

declare -a PROBLEM_SLUGS

ensure_problem_revision() {
  local SLUG="$1"

  psql_exec "
    INSERT INTO app.problem_revisions
      (problem_id, revision, title, statement, difficulty, time_limit_ms,
       memory_limit_mb, checker_code, points, is_active, created_by)
    SELECT p.id, 1, p.title, p.statement, p.difficulty, p.time_limit_ms,
           p.memory_limit_mb, p.checker_code, p.points, TRUE, p.created_by
      FROM app.problems p
     WHERE p.slug = '$SLUG'
    ON CONFLICT (problem_id, revision) DO UPDATE
       SET title = EXCLUDED.title,
           statement = EXCLUDED.statement,
           difficulty = EXCLUDED.difficulty,
           time_limit_ms = EXCLUDED.time_limit_ms,
           memory_limit_mb = EXCLUDED.memory_limit_mb,
           checker_code = EXCLUDED.checker_code,
           points = EXCLUDED.points,
           is_active = TRUE;

    UPDATE app.problem_revisions pr
       SET is_active = FALSE
      FROM app.problems p
     WHERE pr.problem_id = p.id
       AND p.slug = '$SLUG'
       AND pr.revision <> 1;
  "
}

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
    ensure_problem_revision "$SLUG"
  elif [ "$HTTP_CODE" = "409" ]; then
    warn "Problem $SLUG already exists — skipping"
    ensure_problem_revision "$SLUG"
  else
    fail "Failed to create $SLUG (HTTP $HTTP_CODE): $BODY"
  fi
  PROBLEM_SLUGS+=("$SLUG")
}

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
    {"input": "3 6\n3 2 4", "expected_output": "1 2", "is_sample": true},
    {"input": "2 6\n3 3", "expected_output": "0 1", "is_sample": false},
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
    {"input": "hello", "expected_output": "olleh", "is_sample": true},
    {"input": "OpenAI", "expected_output": "IAnepO", "is_sample": true},
    {"input": "a", "expected_output": "a", "is_sample": false},
    {"input": "racecar", "expected_output": "racecar", "is_sample": false},
    {"input": "ab cd ef", "expected_output": "fe dc ba", "is_sample": false}
  ]
}'

# ─── Problem 3: Fibonacci Number ───
create_problem "fibonacci-number" '{
  "title": "Fibonacci Number",
  "slug": "fibonacci-number",
  "difficulty": "easy",
  "time_limit_ms": 1000,
  "memory_limit_mb": 256,
  "statement": "## Fibonacci Number\n\nGiven an integer `n`, return the `n`-th Fibonacci number.\n\nThe Fibonacci sequence is defined as:\n- F(0) = 0\n- F(1) = 1\n- F(n) = F(n-1) + F(n-2) for n > 1\n\n### Input Format\n- A single integer `n`\n\n### Output Format\n- The `n`-th Fibonacci number\n\n### Constraints\n- 0 ≤ n ≤ 45\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 0 | 0 |\n| 1 | 1 |\n| 10 | 55 |",
  "checker_code": "",
  "test_cases": [
    {"input": "0", "expected_output": "0", "is_sample": true},
    {"input": "1", "expected_output": "1", "is_sample": true},
    {"input": "10", "expected_output": "55", "is_sample": true},
    {"input": "20", "expected_output": "6765", "is_sample": false},
    {"input": "45", "expected_output": "1134903170", "is_sample": false}
  ]
}'

# ─── Problem 4: Valid Parentheses ───
create_problem "valid-parentheses" '{
  "title": "Valid Parentheses",
  "slug": "valid-parentheses",
  "difficulty": "easy",
  "time_limit_ms": 1000,
  "memory_limit_mb": 256,
  "statement": "## Valid Parentheses\n\nGiven a string `s` containing just the characters `(`, `)`, `{`, `}`, `[` and `]`, determine if the input string is valid.\n\nA string is valid if:\n1. Open brackets are closed by the same type of brackets.\n2. Open brackets are closed in the correct order.\n3. Every close bracket has a corresponding open bracket of the same type.\n\nPrint `YES` if valid, `NO` otherwise.\n\n### Input Format\n- A single line containing the string `s`\n\n### Output Format\n- `YES` or `NO`\n\n### Constraints\n- 1 ≤ |s| ≤ 10^4\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| () | YES |\n| ()[]{} | YES |\n| (] | NO |",
  "checker_code": "",
  "test_cases": [
    {"input": "()", "expected_output": "YES", "is_sample": true},
    {"input": "()[]{}", "expected_output": "YES", "is_sample": true},
    {"input": "(]", "expected_output": "NO", "is_sample": true},
    {"input": "((()))", "expected_output": "YES", "is_sample": false},
    {"input": "{[()]}", "expected_output": "YES", "is_sample": false},
    {"input": "(()", "expected_output": "NO", "is_sample": false},
    {"input": "}{", "expected_output": "NO", "is_sample": false}
  ]
}'

# ─── Problem 5: Maximum Subarray ───
create_problem "maximum-subarray" '{
  "title": "Maximum Subarray",
  "slug": "maximum-subarray",
  "difficulty": "medium",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Maximum Subarray\n\nGiven an integer array `nums`, find the subarray with the largest sum, and return its sum.\n\n### Input Format\n- First line: integer `n`\n- Second line: `n` space-separated integers\n\n### Output Format\n- A single integer: the maximum subarray sum\n\n### Constraints\n- 1 ≤ n ≤ 10^5\n- -10^4 ≤ nums[i] ≤ 10^4\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 9\\n-2 1 -3 4 -1 2 1 -5 4 | 6 |\n| 1\\n1 | 1 |",
  "checker_code": "",
  "test_cases": [
    {"input": "9\n-2 1 -3 4 -1 2 1 -5 4", "expected_output": "6", "is_sample": true},
    {"input": "1\n1", "expected_output": "1", "is_sample": true},
    {"input": "5\n5 4 -1 7 8", "expected_output": "23", "is_sample": false},
    {"input": "3\n-1 -2 -3", "expected_output": "-1", "is_sample": false},
    {"input": "6\n1 -1 1 -1 1 -1", "expected_output": "1", "is_sample": false}
  ]
}'

# ─── Problem 6: Merge Sorted Arrays ───
create_problem "merge-sorted-arrays" '{
  "title": "Merge Sorted Arrays",
  "slug": "merge-sorted-arrays",
  "difficulty": "medium",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Merge Sorted Arrays\n\nGiven two sorted integer arrays, merge them into one sorted array.\n\n### Input Format\n- First line: integer `n`\n- Second line: `n` sorted space-separated integers\n- Third line: integer `m`\n- Fourth line: `m` sorted space-separated integers\n\n### Output Format\n- A single line of space-separated integers: the merged sorted array\n\n### Constraints\n- 0 ≤ n, m ≤ 10^5\n- -10^9 ≤ elements ≤ 10^9\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 3\\n1 2 4\\n3\\n1 3 4 | 1 1 2 3 4 4 |",
  "checker_code": "",
  "test_cases": [
    {"input": "3\n1 2 4\n3\n1 3 4", "expected_output": "1 1 2 3 4 4", "is_sample": true},
    {"input": "1\n1\n0\n", "expected_output": "1", "is_sample": true},
    {"input": "0\n\n1\n5", "expected_output": "5", "is_sample": false},
    {"input": "4\n-5 -3 0 2\n3\n-4 1 6", "expected_output": "-5 -4 -3 0 1 2 6", "is_sample": false},
    {"input": "3\n1 1 1\n3\n1 1 1", "expected_output": "1 1 1 1 1 1", "is_sample": false}
  ]
}'

# ─── Problem 7: Longest Common Subsequence ───
create_problem "longest-common-subsequence" '{
  "title": "Longest Common Subsequence",
  "slug": "longest-common-subsequence",
  "difficulty": "medium",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Longest Common Subsequence\n\nGiven two strings `text1` and `text2`, return the length of their longest common subsequence. If there is no common subsequence, return `0`.\n\n### Input Format\n- First line: string `text1`\n- Second line: string `text2`\n\n### Output Format\n- A single integer: the length of the LCS\n\n### Constraints\n- 1 ≤ |text1|, |text2| ≤ 1000\n- Strings consist of lowercase English letters only\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| abcde\\nace | 3 |\n| abc\\nabc | 3 |\n| abc\\ndef | 0 |",
  "checker_code": "",
  "test_cases": [
    {"input": "abcde\nace", "expected_output": "3", "is_sample": true},
    {"input": "abc\nabc", "expected_output": "3", "is_sample": true},
    {"input": "abc\ndef", "expected_output": "0", "is_sample": true},
    {"input": "oxcpqrsvwf\nshmtulqrypy", "expected_output": "2", "is_sample": false},
    {"input": "abcba\nabcbcba", "expected_output": "5", "is_sample": false}
  ]
}'

# ─── Problem 8: Binary Search ───
create_problem "binary-search" '{
  "title": "Binary Search",
  "slug": "binary-search",
  "difficulty": "easy",
  "time_limit_ms": 1000,
  "memory_limit_mb": 256,
  "statement": "## Binary Search\n\nGiven a sorted array of integers `nums` and a target value `target`, return the index of `target` in the array. If `target` is not found, return `-1`.\n\n### Input Format\n- First line: two integers `n` and `target`\n- Second line: `n` sorted space-separated integers\n\n### Output Format\n- A single integer: the index (0-based) or `-1`\n\n### Constraints\n- 1 ≤ n ≤ 10^5\n- -10^9 ≤ nums[i], target ≤ 10^9\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 6 9\\n-1 0 3 5 9 12 | 4 |\n| 6 2\\n-1 0 3 5 9 12 | -1 |",
  "checker_code": "",
  "test_cases": [
    {"input": "6 9\n-1 0 3 5 9 12", "expected_output": "4", "is_sample": true},
    {"input": "6 2\n-1 0 3 5 9 12", "expected_output": "-1", "is_sample": true},
    {"input": "1 5\n5", "expected_output": "0", "is_sample": false},
    {"input": "1 1\n5", "expected_output": "-1", "is_sample": false},
    {"input": "5 3\n1 2 3 4 5", "expected_output": "2", "is_sample": false}
  ]
}'

# ─── Problem 9: Coin Change ───
create_problem "coin-change" '{
  "title": "Coin Change",
  "slug": "coin-change",
  "difficulty": "medium",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Coin Change\n\nYou are given an integer array `coins` representing coins of different denominations and an integer `amount` representing a total amount of money.\n\nReturn the **fewest number of coins** needed to make up that amount. If that amount cannot be made up, return `-1`.\n\nYou may assume you have an infinite number of each kind of coin.\n\n### Input Format\n- First line: two integers `n` and `amount`\n- Second line: `n` space-separated integers (coin denominations)\n\n### Output Format\n- A single integer\n\n### Constraints\n- 1 ≤ n ≤ 12\n- 1 ≤ coins[i] ≤ 2^31 - 1\n- 0 ≤ amount ≤ 10^4\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 3 11\\n1 5 2 | 3 |\n| 1 3\\n2 | -1 |\n| 1 0\\n1 | 0 |",
  "checker_code": "",
  "test_cases": [
    {"input": "3 11\n1 5 2", "expected_output": "3", "is_sample": true},
    {"input": "1 3\n2", "expected_output": "-1", "is_sample": true},
    {"input": "1 0\n1", "expected_output": "0", "is_sample": true},
    {"input": "3 6\n1 3 4", "expected_output": "2", "is_sample": false},
    {"input": "2 100\n1 50", "expected_output": "2", "is_sample": false}
  ]
}'

# ─── Problem 10: N-Queens ───
create_problem "n-queens" '{
  "title": "N-Queens",
  "slug": "n-queens",
  "difficulty": "hard",
  "time_limit_ms": 3000,
  "memory_limit_mb": 256,
  "statement": "## N-Queens\n\nThe **N-Queens** puzzle is the problem of placing `n` queens on an `n x n` chessboard such that no two queens attack each other.\n\nGiven an integer `n`, return the **number** of distinct solutions to the N-Queens puzzle.\n\n### Input Format\n- A single integer `n`\n\n### Output Format\n- A single integer: the number of distinct solutions\n\n### Constraints\n- 1 ≤ n ≤ 12\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 4 | 2 |\n| 1 | 1 |\n| 8 | 92 |",
  "checker_code": "",
  "test_cases": [
    {"input": "4", "expected_output": "2", "is_sample": true},
    {"input": "1", "expected_output": "1", "is_sample": true},
    {"input": "8", "expected_output": "92", "is_sample": true},
    {"input": "5", "expected_output": "10", "is_sample": false},
    {"input": "9", "expected_output": "352", "is_sample": false},
    {"input": "12", "expected_output": "14200", "is_sample": false}
  ]
}'

# ─── Problem 11: Shortest Path in Grid ───
create_problem "shortest-path-grid" '{
  "title": "Shortest Path in Grid",
  "slug": "shortest-path-grid",
  "difficulty": "hard",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Shortest Path in Grid\n\nYou are given an `m x n` grid. Each cell is either `0` (empty) or `1` (obstacle). Find the length of the shortest path from the top-left corner `(0,0)` to the bottom-right corner `(m-1,n-1)`. You can move in 4 directions (up, down, left, right). The path length is the number of cells visited (including start and end).\n\nIf there is no valid path, return `-1`.\n\n### Input Format\n- First line: two integers `m` and `n`\n- Next `m` lines: `n` space-separated integers (0 or 1)\n\n### Output Format\n- A single integer: the shortest path length or `-1`\n\n### Constraints\n- 1 ≤ m, n ≤ 100\n- Grid[0][0] = 0 and Grid[m-1][n-1] = 0\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 3 3\\n0 0 0\\n1 1 0\\n0 0 0 | 5 |\n| 2 2\\n0 1\\n1 0 | -1 |",
  "checker_code": "",
  "test_cases": [
    {"input": "3 3\n0 0 0\n1 1 0\n0 0 0", "expected_output": "5", "is_sample": true},
    {"input": "2 2\n0 1\n1 0", "expected_output": "-1", "is_sample": true},
    {"input": "1 1\n0", "expected_output": "1", "is_sample": false},
    {"input": "3 3\n0 0 0\n0 0 0\n0 0 0", "expected_output": "5", "is_sample": false},
    {"input": "4 4\n0 0 1 0\n0 0 0 0\n1 1 0 1\n0 0 0 0", "expected_output": "7", "is_sample": false}
  ]
}'

# ─── Problem 12: Detect Cycle in Graph ───
create_problem "detect-cycle-graph" '{
  "title": "Detect Cycle in Directed Graph",
  "slug": "detect-cycle-graph",
  "difficulty": "hard",
  "time_limit_ms": 2000,
  "memory_limit_mb": 256,
  "statement": "## Detect Cycle in Directed Graph\n\nGiven a directed graph with `n` vertices (numbered 1 to n) and `m` edges, determine if the graph contains a cycle.\n\nPrint `YES` if the graph has a cycle, `NO` otherwise.\n\n### Input Format\n- First line: two integers `n` and `m`\n- Next `m` lines: two integers `u v` representing a directed edge from `u` to `v`\n\n### Output Format\n- `YES` or `NO`\n\n### Constraints\n- 1 ≤ n ≤ 10^5\n- 0 ≤ m ≤ 2 × 10^5\n\n### Examples\n\n| Input | Output |\n|-------|--------|\n| 4 4\\n1 2\\n2 3\\n3 4\\n4 2 | YES |\n| 3 2\\n1 2\\n1 3 | NO |",
  "checker_code": "",
  "test_cases": [
    {"input": "4 4\n1 2\n2 3\n3 4\n4 2", "expected_output": "YES", "is_sample": true},
    {"input": "3 2\n1 2\n1 3", "expected_output": "NO", "is_sample": true},
    {"input": "1 0", "expected_output": "NO", "is_sample": false},
    {"input": "2 2\n1 2\n2 1", "expected_output": "YES", "is_sample": false},
    {"input": "5 5\n1 2\n2 3\n3 4\n4 5\n5 1", "expected_output": "YES", "is_sample": false}
  ]
}'

echo ""

# ----------------------------------------------------------
# 3. Fetch problem IDs for contest creation
# ----------------------------------------------------------
echo "── Fetching Problem IDs ────────────────────────────"

get_problem_id() {
  local slug="$1"
  psql_query "SELECT id FROM app.problems WHERE slug = '$slug' LIMIT 1;"
}

TWO_SUM_ID=$(get_problem_id "two-sum")
REVERSE_STRING_ID=$(get_problem_id "reverse-string")
FIBONACCI_ID=$(get_problem_id "fibonacci-number")
PARENTHESES_ID=$(get_problem_id "valid-parentheses")
MAX_SUBARRAY_ID=$(get_problem_id "maximum-subarray")
MERGE_ARRAYS_ID=$(get_problem_id "merge-sorted-arrays")
LCS_ID=$(get_problem_id "longest-common-subsequence")
BINARY_SEARCH_ID=$(get_problem_id "binary-search")
COIN_CHANGE_ID=$(get_problem_id "coin-change")
NQUEENS_ID=$(get_problem_id "n-queens")
SHORTEST_PATH_ID=$(get_problem_id "shortest-path-grid")
CYCLE_DETECT_ID=$(get_problem_id "detect-cycle-graph")

info "Fetched problem IDs"
echo ""

# ----------------------------------------------------------
# 2b. Assign tags to problems
# ----------------------------------------------------------
echo "── Assigning Tags to Problems ────────────────────────"

assign_tags() {
  local SLUG="$1"
  shift
  local TAGS_JSON="["
  local FIRST=true
  for TAG in "$@"; do
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      TAGS_JSON+=","
    fi
    TAGS_JSON+="\"$TAG\""
  done
  TAGS_JSON+="]"

  RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$API/questions/$SLUG/tags" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"tags\": $TAGS_JSON}" 2>/dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  if [ "$HTTP_CODE" = "200" ]; then
    success "Tagged $SLUG"
  else
    fail "Failed to tag $SLUG (HTTP $HTTP_CODE)"
  fi
}

assign_tags "two-sum"                  "Array" "Two Pointers" "Hash Table"
assign_tags "reverse-string"           "String" "Two Pointers"
assign_tags "fibonacci-number"         "Math" "Dynamic Programming" "Recursion"
assign_tags "valid-parentheses"        "String" "Stack"
assign_tags "maximum-subarray"         "Array" "Dynamic Programming" "Greedy"
assign_tags "merge-sorted-arrays"      "Array" "Two Pointers" "Sorting"
assign_tags "longest-common-subsequence" "String" "Dynamic Programming"
assign_tags "binary-search"            "Array" "Binary Search"
assign_tags "coin-change"              "Array" "Dynamic Programming" "Greedy"
assign_tags "n-queens"                 "Array" "Backtracking" "Recursion"
assign_tags "shortest-path-grid"       "Array" "Graph" "Queue"
assign_tags "detect-cycle-graph"       "Graph" "Tree" "Recursion"

echo ""

# ----------------------------------------------------------
# 4. Seed advanced problem components + publish problems
# ----------------------------------------------------------
echo "── Seeding Validators / Checkers / Generators ────────"

create_component() {
  local PROBLEM_ID="$1"
  local COMPONENT_TYPE="$2"
  local PAYLOAD="$3"
  local LABEL="$4"

  if [ -z "$PROBLEM_ID" ]; then
    warn "Skipping $LABEL — missing problem id"
    return
  fi

  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/admin/problems/$PROBLEM_ID/$COMPONENT_TYPE" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "$PAYLOAD" 2>/dev/null)
  HTTP_CODE=$(echo "$RESPONSE" | tail -1)

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    success "$LABEL"
  else
    warn "Could not seed $LABEL (HTTP $HTTP_CODE)"
  fi
}

# two-sum: standard validator + checker + canonical AC solution
create_component "$TWO_SUM_ID" "validators" '{
  "name": "nums-range-validator",
  "source_code": "#include <bits/stdc++.h>\nusing namespace std;\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; long long target; if(!(cin>>n>>target)) return 1; if(n<2||n>100000) return 1; for(int i=0;i<n;i++){ long long x; if(!(cin>>x)) return 1; if(x < -1000000000LL || x > 1000000000LL) return 1; } return 0;}"
}' "Seeded validator for two-sum"

create_component "$TWO_SUM_ID" "checkers" '{
  "name": "exact-output-checker",
  "checker_type": "standard",
  "source_code": "#include <bits/stdc++.h>\nusing namespace std;\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);string a,b;getline(cin,a);getline(cin,b);while(!a.empty()&&(a.back()==char(13)||a.back()==char(10)||isspace((unsigned char)a.back())))a.pop_back();while(!b.empty()&&(b.back()==char(13)||b.back()==char(10)||isspace((unsigned char)b.back())))b.pop_back();return a==b?0:1;}"
}' "Seeded checker for two-sum"

create_component "$TWO_SUM_ID" "solutions" '{
  "name": "two-sum-ac",
  "expected_verdict": "AC",
  "tag": "main",
  "source_code": "#include <bits/stdc++.h>\nusing namespace std;\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; long long target; if(!(cin>>n>>target)) return 0; vector<long long>a(n); for(int i=0;i<n;i++)cin>>a[i]; unordered_map<long long,int> mp; for(int i=0;i<n;i++){ long long need=target-a[i]; if(mp.count(need)){ cout<<mp[need]<<\" \"<<i<<\"\\n\"; return 0; } mp[a[i]]=i; } return 0;}"
}' "Seeded AC solution for two-sum"

# fibonacci: generator + alt AC solution
create_component "$FIBONACCI_ID" "generators" '{
  "name": "small-random-n",
  "description": "Generates random n in [0,45]",
  "source_code": "#include <bits/stdc++.h>\nusing namespace std;\nint main(int argc,char** argv){ mt19937 rng((uint32_t)chrono::steady_clock::now().time_since_epoch().count()); uniform_int_distribution<int> dist(0,45); cout<<dist(rng)<<\"\\n\"; return 0; }"
}' "Seeded generator for fibonacci"

create_component "$FIBONACCI_ID" "solutions" '{
  "name": "fibonacci-dp-ac",
  "expected_verdict": "AC",
  "tag": "main",
  "source_code": "#include <bits/stdc++.h>\nusing namespace std;\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);int n; if(!(cin>>n)) return 0; long long a=0,b=1; for(int i=0;i<n;i++){ long long c=a+b; a=b; b=c; } cout<<a<<\"\\n\"; return 0;}"
}' "Seeded AC solution for fibonacci"

# maximum-subarray: partial checker seed example
create_component "$MAX_SUBARRAY_ID" "checkers" '{
  "name": "whitespace-insensitive-checker",
  "checker_type": "partial",
  "source_code": "#include <bits/stdc++.h>\nusing namespace std;\nstring norm(const string&s){ string t; for(char c:s) if(!isspace((unsigned char)c)) t.push_back(c); return t; }\nint main(){ios::sync_with_stdio(false);cin.tie(nullptr);string jury,cont;getline(cin,jury);getline(cin,cont);return norm(jury)==norm(cont)?0:1;}"
}' "Seeded partial-style checker for maximum-subarray"

# shortest-path-grid: interactor + wrong answer solution for testing panel
create_component "$SHORTEST_PATH_ID" "interactors" '{
  "name": "dummy-grid-interactor",
  "source_code": "#include <bits/stdc++.h>\nusing namespace std;\nint main(){ return 0; }"
}' "Seeded interactor for shortest-path-grid"

create_component "$SHORTEST_PATH_ID" "solutions" '{
  "name": "intentional-wa",
  "expected_verdict": "WA",
  "tag": "negative",
  "source_code": "#include <bits/stdc++.h>\nusing namespace std;\nint main(){ cout<<-1<<\"\\n\"; return 0; }"
}' "Seeded WA solution for shortest-path-grid"

echo ""
echo "── Publishing Created Problems ───────────────────────"

publish_problem() {
  local PID="$1"
  local LABEL="$2"
  [ -z "$PID" ] && return
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/admin/problems/$PID/publish" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d '{}' 2>/dev/null)
  CODE=$(echo "$RESPONSE" | tail -1)
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    success "Published $LABEL"
  else
    warn "Could not publish $LABEL (HTTP $CODE)"
  fi
}

publish_problem "$TWO_SUM_ID" "two-sum"
publish_problem "$REVERSE_STRING_ID" "reverse-string"
publish_problem "$FIBONACCI_ID" "fibonacci-number"
publish_problem "$PARENTHESES_ID" "valid-parentheses"
publish_problem "$MAX_SUBARRAY_ID" "maximum-subarray"
publish_problem "$MERGE_ARRAYS_ID" "merge-sorted-arrays"
publish_problem "$LCS_ID" "longest-common-subsequence"
publish_problem "$BINARY_SEARCH_ID" "binary-search"
publish_problem "$COIN_CHANGE_ID" "coin-change"
publish_problem "$NQUEENS_ID" "n-queens"
publish_problem "$SHORTEST_PATH_ID" "shortest-path-grid"
publish_problem "$CYCLE_DETECT_ID" "detect-cycle-graph"

echo ""

# ----------------------------------------------------------
# 5. Create contests
# ----------------------------------------------------------
echo "── Creating Contests ─────────────────────────────────"

# Contest 1: Beginner Challenge (ended — in the past)
PAST_START="2026-02-20T10:00:00Z"
PAST_END="2026-02-20T12:00:00Z"

if [ -n "$TWO_SUM_ID" ] && [ -n "$REVERSE_STRING_ID" ] && [ -n "$FIBONACCI_ID" ] && [ -n "$PARENTHESES_ID" ]; then
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/contests" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{
      \"title\": \"Beginner Challenge #1\",
      \"description\": \"A friendly contest for newcomers. Easy problems to get you started!\",
      \"start_time\": \"$PAST_START\",
      \"end_time\": \"$PAST_END\",
      \"is_rated\": true,
      \"problems\": [
        {\"problem_id\": $TWO_SUM_ID, \"points\": 100, \"problem_order\": 1},
        {\"problem_id\": $REVERSE_STRING_ID, \"points\": 100, \"problem_order\": 2},
        {\"problem_id\": $FIBONACCI_ID, \"points\": 150, \"problem_order\": 3},
        {\"problem_id\": $PARENTHESES_ID, \"points\": 150, \"problem_order\": 4}
      ]
    }" 2>/dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    success "Created contest: Beginner Challenge #1 (ended)"
  else
    fail "Failed to create Beginner Challenge (HTTP $HTTP_CODE)"
  fi
else
  warn "Skipping Beginner Challenge — missing problem IDs"
fi

# Contest 2: Intermediate Round (upcoming — in the future)
FUTURE_START="2026-03-01T14:00:00Z"
FUTURE_END="2026-03-01T17:00:00Z"

if [ -n "$MAX_SUBARRAY_ID" ] && [ -n "$MERGE_ARRAYS_ID" ] && [ -n "$LCS_ID" ] && [ -n "$COIN_CHANGE_ID" ]; then
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/contests" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{
      \"title\": \"Intermediate Round #1\",
      \"description\": \"Step up your game! Medium difficulty problems to test your algorithmic skills.\",
      \"start_time\": \"$FUTURE_START\",
      \"end_time\": \"$FUTURE_END\",
      \"is_rated\": true,
      \"problems\": [
        {\"problem_id\": $MAX_SUBARRAY_ID, \"points\": 200, \"problem_order\": 1},
        {\"problem_id\": $MERGE_ARRAYS_ID, \"points\": 200, \"problem_order\": 2},
        {\"problem_id\": $LCS_ID, \"points\": 300, \"problem_order\": 3},
        {\"problem_id\": $COIN_CHANGE_ID, \"points\": 300, \"problem_order\": 4}
      ]
    }" 2>/dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    success "Created contest: Intermediate Round #1 (upcoming)"
  else
    fail "Failed to create Intermediate Round (HTTP $HTTP_CODE)"
  fi
else
  warn "Skipping Intermediate Round — missing problem IDs"
fi

# Contest 3: Advanced Championship (further future)
ADV_START="2026-03-15T09:00:00Z"
ADV_END="2026-03-15T14:00:00Z"

if [ -n "$NQUEENS_ID" ] && [ -n "$SHORTEST_PATH_ID" ] && [ -n "$CYCLE_DETECT_ID" ] && [ -n "$BINARY_SEARCH_ID" ]; then
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/contests" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{
      \"title\": \"Advanced Championship\",
      \"description\": \"The ultimate test. Hard problems for seasoned programmers. 5 hours, no mercy.\",
      \"start_time\": \"$ADV_START\",
      \"end_time\": \"$ADV_END\",
      \"is_rated\": true,
      \"problems\": [
        {\"problem_id\": $BINARY_SEARCH_ID, \"points\": 150, \"problem_order\": 1},
        {\"problem_id\": $NQUEENS_ID, \"points\": 400, \"problem_order\": 2},
        {\"problem_id\": $SHORTEST_PATH_ID, \"points\": 400, \"problem_order\": 3},
        {\"problem_id\": $CYCLE_DETECT_ID, \"points\": 500, \"problem_order\": 4}
      ]
    }" 2>/dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    success "Created contest: Advanced Championship (upcoming)"
  else
    fail "Failed to create Advanced Championship (HTTP $HTTP_CODE)"
  fi
else
  warn "Skipping Advanced Championship — missing problem IDs"
fi

echo ""

# ----------------------------------------------------------
# 6. Subjective problem (manual-grading only)
# ----------------------------------------------------------
echo "── Creating Subjective Problem ───────────────────────"

SUBJECTIVE_SLUG="essay-binary-search"
SUBJECTIVE_ID=$(psql_query "SELECT id FROM app.problems WHERE slug = '$SUBJECTIVE_SLUG' LIMIT 1;")

if [ -z "$SUBJECTIVE_ID" ]; then
  SUBJECTIVE_STATEMENT='## Design: Binary Search Variants\n\nImplement binary search in C++ and briefly explain (in comments) the invariant you maintain.\n\nYour submission will be **manually reviewed**. There are no automated test cases — focus on clarity, correctness of the invariant, and edge-case handling.\n\n### Deliverable\n- A complete, compilable C++ program that reads `n target` then `n` sorted integers and prints the index (0-based) or `-1`.\n- In comments at the top, state (1) your loop invariant and (2) why the loop terminates.'
  SUBJECTIVE_ID=$(psql_query "INSERT INTO app.problems (title, slug, statement, difficulty, time_limit_ms, memory_limit_mb, problem_type, created_by)
     VALUES ('Binary Search: Design & Explain', '$SUBJECTIVE_SLUG', E'$SUBJECTIVE_STATEMENT', 'medium', 2000, 256, 'subjective',
             (SELECT id FROM app.users WHERE username='admin'))
     RETURNING id;")
  if [ -n "$SUBJECTIVE_ID" ]; then
    success "Created subjective problem: $SUBJECTIVE_SLUG (id=$SUBJECTIVE_ID)"
  else
    fail "Failed to create subjective problem"
  fi
else
  warn "Subjective problem $SUBJECTIVE_SLUG already exists (id=$SUBJECTIVE_ID) — skipping"
fi
echo ""

# ----------------------------------------------------------
# 7. Create a group + members + pending join request
# ----------------------------------------------------------
echo "── Creating Group & Members ──────────────────────────"

# Fetch user IDs (we need them for the group creation and member addition)
ALICE_ID=$(psql_query "SELECT id FROM app.users WHERE username = 'alice'   LIMIT 1;")
BOB_ID=$(psql_query   "SELECT id FROM app.users WHERE username = 'bob'     LIMIT 1;")
CHARLIE_ID=$(psql_query "SELECT id FROM app.users WHERE username = 'charlie' LIMIT 1;")
DIANA_ID=$(psql_query "SELECT id FROM app.users WHERE username = 'diana'   LIMIT 1;")

GROUP_NAME="CS101 Spring 2026"
GROUP_ID=""

# Try to create the group — handle the "already exists" case gracefully.
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
  GROUP_ID=$(psql_query "SELECT id FROM app.groups WHERE name = '$GROUP_NAME' LIMIT 1;")
  warn "Group already exists (id=$GROUP_ID) — reusing"
else
  fail "Failed to create group (HTTP $HTTP_CODE): $BODY"
fi

add_group_member() {
  local USER_ID="$1"
  local ROLE="$2"
  [ -z "$USER_ID" ] && return
  [ -z "$GROUP_ID" ] && return
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/admin/groups/$GROUP_ID/members" \
    -H "$CONTENT_TYPE" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"user_id\": $USER_ID, \"role\": \"$ROLE\"}" 2>/dev/null)
  CODE=$(echo "$RESPONSE" | tail -1)
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    success "Added user #$USER_ID as $ROLE"
  else
    warn "Could not add user #$USER_ID (HTTP $CODE)"
  fi
}

if [ -n "$GROUP_ID" ]; then
  add_group_member "$ALICE_ID" "member"
  add_group_member "$BOB_ID"   "member"
  # charlie was added as admin in the create call, but make sure
  [ -n "$CHARLIE_ID" ] && add_group_member "$CHARLIE_ID" "admin"

  # Create a pending join request from diana (so admins can demo the approval flow)
  if [ -n "$DIANA_ID" ]; then
    psql_exec "INSERT INTO app.group_join_requests (group_id, user_id, status, message)
       VALUES ($GROUP_ID, $DIANA_ID, 'pending', 'Hi! I''m a CS101 student — please add me.')
       ON CONFLICT DO NOTHING;"
    success "Created pending join request from diana"
  fi
fi
echo ""

# ----------------------------------------------------------
# 8. Group-only contest (proctored, subjective + standard, partial scoring)
# ----------------------------------------------------------
echo "── Creating Group Contest ────────────────────────────"

GROUP_CONTEST_START="2026-04-01T09:00:00Z"
GROUP_CONTEST_END="2026-04-01T12:00:00Z"

if [ -n "$GROUP_ID" ] && [ -n "$TWO_SUM_ID" ] && [ -n "$FIBONACCI_ID" ] && [ -n "$SUBJECTIVE_ID" ]; then
  # The seed is also idempotent: skip if a contest with this title already exists for the group.
  EXISTING=$(psql_query "SELECT id FROM app.contests WHERE group_id = $GROUP_ID AND title = 'CS101 Assignment 1' LIMIT 1;")

  if [ -n "$EXISTING" ]; then
    warn "Group contest 'CS101 Assignment 1' already exists (id=$EXISTING) — skipping"
  else
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API/contests" \
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

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
      success "Created group contest 'CS101 Assignment 1' (proctored, group-visible)"
    else
      fail "Failed to create group contest (HTTP $HTTP_CODE): $(echo "$RESPONSE" | sed '$d')"
    fi
  fi
else
  warn "Skipping group contest — missing group or problem IDs"
fi
echo ""

# ----------------------------------------------------------
# 9. Summary
# ----------------------------------------------------------
echo "═══════════════════════════════════════════════════"
echo "  Seed Complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Users:     ${#USERNAMES[@]} (admin, alice, bob, charlie, diana, eve)"
echo "  Password:  $PASSWORD (for all users)"
echo "  Roles:     admin → site admin | others → user"
echo "  Problems:  13 (12 standard + 1 subjective, all tagged)"
echo "  Contests:  4 (3 global + 1 group-only, proctored, partial scoring)"
echo "  Groups:    1 (CS101 Spring 2026)"
echo "             • admin, charlie → group admins"
echo "             • alice, bob     → members"
echo "             • diana          → pending join request"
echo ""
echo "  Frontend:      http://localhost:8080 (any user)"
echo "  Admin Portal:  http://localhost:8081 (admin / $PASSWORD)"
echo ""

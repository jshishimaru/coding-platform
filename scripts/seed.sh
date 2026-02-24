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

ADMIN_TOKEN="${TOKENS[0]}"
if [ -z "$ADMIN_TOKEN" ]; then
  fail "No admin token available. Cannot continue."
  exit 1
fi
echo ""

# ----------------------------------------------------------
# 2. Create problems (questions with test cases)
# ----------------------------------------------------------
echo "── Creating Problems ─────────────────────────────────"

declare -a PROBLEM_SLUGS

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
  elif [ "$HTTP_CODE" = "409" ]; then
    warn "Problem $SLUG already exists — skipping"
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

QUESTIONS_JSON=$(curl -s "$API/questions" -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null)

get_problem_id() {
  local slug="$1"
  echo "$QUESTIONS_JSON" | grep -o "\"id\":[0-9]*,\"title\":\"[^\"]*\",\"slug\":\"$slug\"" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
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
# 4. Create contests
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
# 5. Summary
# ----------------------------------------------------------
echo "═══════════════════════════════════════════════════"
echo "  Seed Complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Users:     ${#USERNAMES[@]} (admin, alice, bob, charlie, diana, eve)"
echo "  Password:  $PASSWORD (for all users)"
echo "  Problems:  12 (4 easy, 4 medium, 2 hard, 2 hard)"
echo "  Tags:      All 12 problems tagged"
echo "  Contests:  3 (1 ended, 2 upcoming)"
echo ""
echo "  Login at http://localhost:8080 with any user above."
echo ""

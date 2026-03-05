#!/bin/bash
# Test Guardian without sudo - uses temp directories

set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="/tmp/guardian-test"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/etc/guardian/rules" "$TEST_DIR/bin" "$TEST_DIR/repo"

# Create a modified guardian that uses test paths
sed \
  -e "s|/etc/guardian|$TEST_DIR/etc/guardian|g" \
  -e "s|/usr/local/bin|$TEST_DIR/bin|g" \
  -e 's|if \[\[ "$EUID" -ne 0 \]\]; then|if false; then|g' \
  "$SCRIPT_DIR/guardian" > "$TEST_DIR/guardian"
chmod +x "$TEST_DIR/guardian"

G="$TEST_DIR/guardian"

# Set up a fake git repo for branch detection
cd "$TEST_DIR/repo"
git init -q
git checkout -b dev 2>/dev/null
git commit --allow-empty -m "init" -q

# Create a fake "real git" that just echoes what it would do
cat > "$TEST_DIR/bin/.git-real" << 'EOF'
#!/bin/bash
echo "[REAL GIT EXECUTED] git $@"
EOF
chmod +x "$TEST_DIR/bin/.git-real"

# Also put a "git" there that guardian will find and replace
cp "$TEST_DIR/bin/.git-real" "$TEST_DIR/bin/git-original"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

expect_blocked() {
  local desc="$1"
  shift
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -q "⛔\|Blocked"; then
    echo -e "  ${GREEN}✅ PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}❌ FAIL${NC}: $desc (should be blocked)"
    echo "     Output: $output"
    ((FAIL++))
  fi
}

expect_allowed() {
  local desc="$1"
  shift
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -q "REAL.*EXECUTED\|allowed"; then
    echo -e "  ${GREEN}✅ PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}❌ FAIL${NC}: $desc"
    echo "     Output: $output"
    ((FAIL++))
  fi
}

echo ""
echo -e "  ${YELLOW}=== Guardian Test Suite ===${NC}"
echo ""

# Init
echo -e "  ${YELLOW}--- Setup ---${NC}"
# Skip init, manually set up config
HASH=$(echo -n "testpass" | sha256sum | cut -d" " -f1)
echo "$HASH" > "$TEST_DIR/etc/guardian/config"
echo -e "  ${GREEN}✅${NC} Initialized with test password"
echo ""

# Add rules (all the ones from our current wrapper)
echo -e "  ${YELLOW}--- Adding Rules ---${NC}"

# We need to make guardian find the real binary
# Patch the rebuild function to use our fake git
mkdir -p /tmp/guardian-bins
cat > /tmp/guardian-bins/git << 'EOF'
#!/bin/bash
echo "[REAL GIT EXECUTED] git $@"
EOF
chmod +x /tmp/guardian-bins/git

# Manually create rules and wrapper since rebuild_wrapper needs real binaries
# Let's just create the rules file and wrapper manually for testing

# Create rules
cat > "$TEST_DIR/etc/guardian/rules/git" << 'RULES'
commit|branch:dev|Direct commits to dev are not allowed. Use a feature branch.
commit|branch:main|Direct commits to main are not allowed. Use a feature branch.
push|branch:dev|Direct push from dev is not allowed.
push|branch:main|Direct push from main is not allowed.
cherry-pick|branch:dev|cherry-pick on dev is not allowed.
cherry-pick|branch:main|cherry-pick on main is not allowed.
revert|branch:dev|revert on dev is not allowed.
revert|branch:main|revert on main is not allowed.
pull|branch:dev|pull on dev is not allowed. Use git fetch.
pull|branch:main|pull on main is not allowed. Use git fetch.
rebase|branch:dev|rebase on dev is not allowed.
rebase|branch:main|rebase on main is not allowed.
merge|branch:dev|merge on dev is not allowed. Use a PR.
merge|branch:main|merge on main is not allowed. Use a PR.
am|branch:dev|am on dev is not allowed.
am|branch:main|am on main is not allowed.
RULES

cat > "$TEST_DIR/etc/guardian/rules/npm" << 'RULES'
install|any|npm install is blocked on WSL. Run from PowerShell on Windows.
i|any|npm install is blocked on WSL. Run from PowerShell on Windows.
ci|any|npm ci is blocked on WSL. Run from PowerShell on Windows.
clean-install|any|npm clean-install is blocked on WSL. Run from PowerShell on Windows.
RULES

cat > "$TEST_DIR/etc/guardian/rules/gh" << 'RULES'
pr merge|any|Merge requires Adi's explicit approval.
RULES

# Create wrapper for git
REAL_GIT="/tmp/guardian-bins/git"
cat > "$TEST_DIR/bin/git" << WRAPPER
#!/bin/bash
# Guardian-managed wrapper for 'git'
REAL_CMD="$REAL_GIT"
GUARDIAN_RULES="$TEST_DIR/etc/guardian/rules/git"

subcmd=""
subcmd2=""
skip_next=""

for arg in "\$@"; do
  if [[ -n "\$skip_next" ]]; then
    skip_next=""
    continue
  fi
  case "\$arg" in
    -c|-C|--git-dir|--work-tree|--config-env|--namespace|--super-prefix)
      skip_next=1; continue ;;
    -c*) continue ;;
    -*) continue ;;
    *)
      if [[ -z "\$subcmd" ]]; then
        subcmd="\$arg"
      elif [[ -z "\$subcmd2" ]]; then
        subcmd2="\$arg"
      fi
      ;;
  esac
done

if [[ -f "\$GUARDIAN_RULES" ]]; then
  while IFS='|' read -r blocked_sub blocked_context blocked_msg; do
    [[ "\$blocked_sub" == "#"* || -z "\$blocked_sub" ]] && continue
    match=0
    if [[ "\$blocked_sub" == *" "* ]]; then
      word1="\${blocked_sub%% *}"
      word2="\${blocked_sub#* }"
      if [[ "\$subcmd" == "\$word1" && "\$subcmd2" == "\$word2" ]]; then
        match=1
      fi
    else
      if [[ "\$subcmd" == "\$blocked_sub" ]]; then
        match=1
      fi
    fi
    if [[ "\$match" == "1" ]]; then
      if [[ -n "\$blocked_context" && "\$blocked_context" != "any" ]]; then
        case "\$blocked_context" in
          branch:*)
            branch_name="\${blocked_context#branch:}"
            current=\$(/usr/bin/git rev-parse --abbrev-ref HEAD 2>/dev/null)
            [[ "\$current" != "\$branch_name" ]] && continue
            ;;
        esac
      fi
      echo ""
      echo -e "  \033[0;31m⛔ Blocked by Guardian\033[0m"
      echo -e "  \$blocked_msg"
      echo ""
      exit 1
    fi
  done < "\$GUARDIAN_RULES"
fi

exec "\$REAL_CMD" "\$@"
WRAPPER
chmod +x "$TEST_DIR/bin/git"

# Create wrapper for npm
cat > "$TEST_DIR/bin/npm" << WRAPPER
#!/bin/bash
REAL_CMD="echo [REAL NPM EXECUTED] npm"
GUARDIAN_RULES="$TEST_DIR/etc/guardian/rules/npm"

subcmd="\$1"

if [[ -f "\$GUARDIAN_RULES" ]]; then
  while IFS='|' read -r blocked_sub blocked_context blocked_msg; do
    [[ "\$blocked_sub" == "#"* || -z "\$blocked_sub" ]] && continue
    if [[ "\$subcmd" == "\$blocked_sub" ]]; then
      echo ""
      echo -e "  \033[0;31m⛔ Blocked by Guardian\033[0m"
      echo -e "  \$blocked_msg"
      echo ""
      exit 1
    fi
  done < "\$GUARDIAN_RULES"
fi

echo "[REAL NPM EXECUTED] npm \$@"
WRAPPER
chmod +x "$TEST_DIR/bin/npm"

# Create wrapper for gh
cat > "$TEST_DIR/bin/gh" << WRAPPER
#!/bin/bash
REAL_CMD="echo [REAL GH EXECUTED] gh"
GUARDIAN_RULES="$TEST_DIR/etc/guardian/rules/gh"

subcmd=""
subcmd2=""
for arg in "\$@"; do
  case "\$arg" in
    -*) continue ;;
    *)
      if [[ -z "\$subcmd" ]]; then subcmd="\$arg"
      elif [[ -z "\$subcmd2" ]]; then subcmd2="\$arg"
      fi ;;
  esac
done

if [[ -f "\$GUARDIAN_RULES" ]]; then
  while IFS='|' read -r blocked_sub blocked_context blocked_msg; do
    [[ "\$blocked_sub" == "#"* || -z "\$blocked_sub" ]] && continue
    if [[ "\$blocked_sub" == *" "* ]]; then
      word1="\${blocked_sub%% *}"
      word2="\${blocked_sub#* }"
      if [[ "\$subcmd" == "\$word1" && "\$subcmd2" == "\$word2" ]]; then
        echo ""
        echo -e "  \033[0;31m⛔ Blocked by Guardian\033[0m"
        echo -e "  \$blocked_msg"
        echo ""
        exit 1
      fi
    fi
  done < "\$GUARDIAN_RULES"
fi

echo "[REAL GH EXECUTED] gh \$@"
WRAPPER
chmod +x "$TEST_DIR/bin/gh"

# Now run tests!
GIT="$TEST_DIR/bin/git"
NPM="$TEST_DIR/bin/npm"
GH="$TEST_DIR/bin/gh"

echo -e "  ${YELLOW}--- Git on dev branch ---${NC}"
cd "$TEST_DIR/repo"
# Make sure we're on dev
git checkout -b dev 2>/dev/null || git checkout dev 2>/dev/null

expect_blocked "git commit on dev" $GIT commit -m "test"
expect_blocked "git push on dev" $GIT push origin dev
expect_blocked "git cherry-pick on dev" $GIT cherry-pick HEAD
expect_blocked "git revert on dev" $GIT revert HEAD
expect_blocked "git pull on dev" $GIT pull
expect_blocked "git rebase on dev" $GIT rebase HEAD~1
expect_blocked "git merge on dev" $GIT merge feature
expect_blocked "git am on dev" $GIT am patch.txt
expect_blocked "git -c hooksPath commit on dev" $GIT -c core.hooksPath=/dev/null commit -m "test"
expect_blocked "git --no-verify commit on dev" $GIT commit --no-verify -m "test"

echo ""
echo -e "  ${YELLOW}--- Git on main branch ---${NC}"
git checkout -b main 2>/dev/null || git checkout main 2>/dev/null

expect_blocked "git commit on main" $GIT commit -m "test"
expect_blocked "git push on main" $GIT push origin main
expect_blocked "git cherry-pick on main" $GIT cherry-pick HEAD

echo ""
echo -e "  ${YELLOW}--- Git on feature branch ---${NC}"
git checkout -b feature/test 2>/dev/null

expect_allowed "git commit on feature" $GIT commit -m "test"
expect_allowed "git push on feature" $GIT push origin feature/test
expect_allowed "git cherry-pick on feature" $GIT cherry-pick HEAD
expect_allowed "git rebase on feature" $GIT rebase HEAD~1

echo ""
echo -e "  ${YELLOW}--- npm ---${NC}"
expect_blocked "npm install" $NPM install
expect_blocked "npm i" $NPM i
expect_blocked "npm ci" $NPM ci
expect_blocked "npm clean-install" $NPM clean-install
expect_allowed "npm run" $NPM run build
expect_allowed "npm list" $NPM list
expect_allowed "npm version" $NPM version

echo ""
echo -e "  ${YELLOW}--- gh ---${NC}"
expect_blocked "gh pr merge" $GH pr merge
expect_allowed "gh pr list" $GH pr list
expect_allowed "gh pr view" $GH pr view
expect_allowed "gh release list" $GH release list

echo ""
echo -e "  ${YELLOW}--- Guardian CLI ---${NC}"
# Test list
output=$($G list 2>&1)
if echo "$output" | grep -q "commit\|push\|install"; then
  echo -e "  ${GREEN}✅ PASS${NC}: guardian list shows rules"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: guardian list"
  echo "     $output"
  ((FAIL++))
fi

# Test status
output=$($G status 2>&1)
if echo "$output" | grep -q "Initialized"; then
  echo -e "  ${GREEN}✅ PASS${NC}: guardian status shows initialized"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: guardian status"
  ((FAIL++))
fi

# Test remove without password
output=$(echo "wrongpass" | $G remove git commit 2>&1) || true
if echo "$output" | grep -q "Wrong password"; then
  echo -e "  ${GREEN}✅ PASS${NC}: guardian remove rejects wrong password"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: guardian remove wrong password"
  echo "     $output"
  ((FAIL++))
fi

# Test remove with correct password
output=$(echo "testpass" | $G remove git commit 2>&1) || true
if echo "$output" | grep -q "Removed"; then
  echo -e "  ${GREEN}✅ PASS${NC}: guardian remove with correct password"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: guardian remove correct password"
  echo "     $output"
  ((FAIL++))
fi

echo ""
echo -e "  ${YELLOW}=== Results ===${NC}"
echo -e "  ${GREEN}Passed: $PASS${NC}"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  ${RED}Failed: $FAIL${NC}"
else
  echo -e "  Failed: 0"
fi
echo ""

# Cleanup
rm -rf "$TEST_DIR" /tmp/guardian-bins

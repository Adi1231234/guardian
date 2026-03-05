#!/bin/bash
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="/tmp/guardian-test-edge"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/etc/guardian/rules" "$TEST_DIR/bin" "$TEST_DIR/repo"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
PASS=0
FAIL=0

# Setup repo
cd "$TEST_DIR/repo"
git init -q
git checkout -b dev 2>/dev/null
git commit --allow-empty -m "init" -q

# Setup config
HASH=$(echo -n "testpass" | sha256sum | cut -d" " -f1)
echo "$HASH" > "$TEST_DIR/etc/guardian/config"

# Create fake real git
cat > /tmp/guardian-bins-edge/git << 'EOF'
#!/bin/bash
echo "[REAL GIT EXECUTED] git $@"
EOF
mkdir -p /tmp/guardian-bins-edge
cat > /tmp/guardian-bins-edge/git << 'EOF'
#!/bin/bash
echo "[REAL GIT EXECUTED] git $@"
EOF
chmod +x /tmp/guardian-bins-edge/git

cat > /tmp/guardian-bins-edge/npm << 'EOF'
#!/bin/bash
echo "[REAL NPM EXECUTED] npm $@"
EOF
chmod +x /tmp/guardian-bins-edge/npm

cat > /tmp/guardian-bins-edge/gh << 'EOF'
#!/bin/bash
echo "[REAL GH EXECUTED] gh $@"
EOF
chmod +x /tmp/guardian-bins-edge/gh

# Rules
cat > "$TEST_DIR/etc/guardian/rules/git" << 'RULES'
commit|branch:dev|Direct commits to dev are not allowed.
commit|branch:main|Direct commits to main are not allowed.
push|branch:dev|Direct push from dev is not allowed.
push|branch:main|Direct push from main is not allowed.
cherry-pick|branch:dev|cherry-pick on dev is not allowed.
cherry-pick|branch:main|cherry-pick on main is not allowed.
revert|branch:dev|revert on dev is not allowed.
revert|branch:main|revert on main is not allowed.
pull|branch:dev|pull on dev is not allowed.
pull|branch:main|pull on main is not allowed.
rebase|branch:dev|rebase on dev is not allowed.
rebase|branch:main|rebase on main is not allowed.
merge|branch:dev|merge on dev is not allowed.
merge|branch:main|merge on main is not allowed.
am|branch:dev|am on dev is not allowed.
am|branch:main|am on main is not allowed.
reset|branch:dev|reset on dev is not allowed.
reset|branch:main|reset on main is not allowed.
RULES

cat > "$TEST_DIR/etc/guardian/rules/npm" << 'RULES'
install|any|npm install is blocked on WSL.
i|any|npm i is blocked on WSL.
ci|any|npm ci is blocked on WSL.
clean-install|any|npm clean-install is blocked on WSL.
RULES

cat > "$TEST_DIR/etc/guardian/rules/gh" << 'RULES'
pr merge|any|Merge requires Adi's approval.
RULES

# Build wrappers
REAL_GIT="/tmp/guardian-bins-edge/git"
REAL_NPM="/tmp/guardian-bins-edge/npm"
REAL_GH="/tmp/guardian-bins-edge/gh"

# Git wrapper
cat > "$TEST_DIR/bin/git" << WRAPPER
#!/bin/bash
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
      [[ "\$subcmd" == "\$word1" && "\$subcmd2" == "\$word2" ]] && match=1
    else
      [[ "\$subcmd" == "\$blocked_sub" ]] && match=1
    fi
    if [[ "\$match" == "1" ]]; then
      if [[ -n "\$blocked_context" && "\$blocked_context" != "any" ]]; then
        case "\$blocked_context" in
          branch:*)
            branch_name="\${blocked_context#branch:}"
            current=\$(/usr/bin/git rev-parse --abbrev-ref HEAD 2>/dev/null)
            [[ "\$current" != "\$branch_name" ]] && continue
            ;;
          env:*)
            env_check="\${blocked_context#env:}"
            env_key="\${env_check%%=*}"
            env_val="\${env_check#*=}"
            [[ "\${!env_key:-}" != "\$env_val" ]] && continue
            ;;
          flag:*)
            flag="\${blocked_context#flag:}"
            found=0
            for a in "\$@"; do [[ "\$a" == "\$flag" ]] && found=1; done
            [[ "\$found" == "0" ]] && continue
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

# npm wrapper
cat > "$TEST_DIR/bin/npm" << WRAPPER
#!/bin/bash
REAL_CMD="$REAL_NPM"
GUARDIAN_RULES="$TEST_DIR/etc/guardian/rules/npm"
subcmd=""
for arg in "\$@"; do
  case "\$arg" in -*) continue ;; *) if [[ -z "\$subcmd" ]]; then subcmd="\$arg"; fi ;; esac
done
if [[ -f "\$GUARDIAN_RULES" ]]; then
  while IFS='|' read -r blocked_sub blocked_context blocked_msg; do
    [[ "\$blocked_sub" == "#"* || -z "\$blocked_sub" ]] && continue
    [[ "\$subcmd" == "\$blocked_sub" ]] && { echo -e "\n  \033[0;31m⛔ Blocked by Guardian\033[0m\n  \$blocked_msg\n"; exit 1; }
  done < "\$GUARDIAN_RULES"
fi
exec "\$REAL_CMD" "\$@"
WRAPPER
chmod +x "$TEST_DIR/bin/npm"

# gh wrapper
cat > "$TEST_DIR/bin/gh" << WRAPPER
#!/bin/bash
REAL_CMD="$REAL_GH"
GUARDIAN_RULES="$TEST_DIR/etc/guardian/rules/gh"
subcmd=""
subcmd2=""
for arg in "\$@"; do
  case "\$arg" in -*) continue ;; *)
    if [[ -z "\$subcmd" ]]; then subcmd="\$arg"
    elif [[ -z "\$subcmd2" ]]; then subcmd2="\$arg"; fi ;; esac
done
if [[ -f "\$GUARDIAN_RULES" ]]; then
  while IFS='|' read -r blocked_sub blocked_context blocked_msg; do
    [[ "\$blocked_sub" == "#"* || -z "\$blocked_sub" ]] && continue
    if [[ "\$blocked_sub" == *" "* ]]; then
      word1="\${blocked_sub%% *}"
      word2="\${blocked_sub#* }"
      [[ "\$subcmd" == "\$word1" && "\$subcmd2" == "\$word2" ]] && { echo -e "\n  \033[0;31m⛔ Blocked by Guardian\033[0m\n  \$blocked_msg\n"; exit 1; }
    else
      [[ "\$subcmd" == "\$blocked_sub" ]] && { echo -e "\n  \033[0;31m⛔ Blocked by Guardian\033[0m\n  \$blocked_msg\n"; exit 1; }
    fi
  done < "\$GUARDIAN_RULES"
fi
exec "\$REAL_CMD" "\$@"
WRAPPER
chmod +x "$TEST_DIR/bin/gh"

GIT="$TEST_DIR/bin/git"
NPM="$TEST_DIR/bin/npm"
GH="$TEST_DIR/bin/gh"

expect_blocked() {
  local desc="$1"; shift
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -q "⛔\|Blocked"; then
    echo -e "  ${GREEN}✅ PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}❌ FAIL${NC}: $desc (expected BLOCKED)"
    echo "     Output: $output"
    ((FAIL++))
  fi
}

expect_allowed() {
  local desc="$1"; shift
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -q "⛔\|Blocked"; then
    echo -e "  ${RED}❌ FAIL${NC}: $desc (expected ALLOWED but got blocked)"
    echo "     Output: $output"
    ((FAIL++))
  else
    echo -e "  ${GREEN}✅ PASS${NC}: $desc"
    ((PASS++))
  fi
}

echo ""
echo -e "  ${YELLOW}========================================${NC}"
echo -e "  ${YELLOW}    Guardian Edge Case Test Suite${NC}"
echo -e "  ${YELLOW}========================================${NC}"
echo ""

# ============================================
# GIT - BLOCKED ON DEV
# ============================================
echo -e "  ${YELLOW}--- Git: BLOCKED on dev ---${NC}"
cd "$TEST_DIR/repo" && git checkout dev 2>/dev/null

expect_blocked "git commit -m test" $GIT commit -m "test"
expect_blocked "git commit -am test" $GIT commit -am "test"
expect_blocked "git commit --amend" $GIT commit --amend
expect_blocked "git commit --amend --no-edit" $GIT commit --amend --no-edit
expect_blocked "git commit -m test --no-verify" $GIT commit -m "test" --no-verify
expect_blocked "git commit --allow-empty -m test" $GIT commit --allow-empty -m "test"
expect_blocked "git -c user.name=x commit -m test" $GIT -c user.name=x commit -m "test"
expect_blocked "git -c core.hooksPath=/dev/null commit -m test" $GIT -c core.hooksPath=/dev/null commit -m "test"
expect_blocked "git -ccore.hooksPath=/dev/null commit -m test" $GIT -ccore.hooksPath=/dev/null commit -m "test"
expect_blocked "git -C /tmp commit -m test" $GIT -C /tmp commit -m "test"
expect_blocked "git --no-pager commit -m test" $GIT --no-pager commit -m "test"
expect_blocked "git push" $GIT push
expect_blocked "git push origin" $GIT push origin
expect_blocked "git push origin dev" $GIT push origin dev
expect_blocked "git push --force" $GIT push --force
expect_blocked "git push --force-with-lease" $GIT push --force-with-lease
expect_blocked "git push -u origin dev" $GIT push -u origin dev
expect_blocked "git cherry-pick abc123" $GIT cherry-pick abc123
expect_blocked "git cherry-pick HEAD~3..HEAD" $GIT cherry-pick HEAD~3..HEAD
expect_blocked "git revert HEAD" $GIT revert HEAD
expect_blocked "git revert --no-commit HEAD" $GIT revert --no-commit HEAD
expect_blocked "git pull" $GIT pull
expect_blocked "git pull origin dev" $GIT pull origin dev
expect_blocked "git pull --rebase" $GIT pull --rebase
expect_blocked "git rebase main" $GIT rebase main
expect_blocked "git rebase -i HEAD~3" $GIT rebase -i HEAD~3
expect_blocked "git rebase --onto main dev" $GIT rebase --onto main dev
expect_blocked "git merge feature" $GIT merge feature
expect_blocked "git merge --no-ff feature" $GIT merge --no-ff feature
expect_blocked "git merge --squash feature" $GIT merge --squash feature
expect_blocked "git am patch.txt" $GIT am patch.txt
expect_blocked "git am --3way patch.txt" $GIT am --3way patch.txt
expect_blocked "git reset --hard HEAD" $GIT reset --hard HEAD
expect_blocked "git reset --mixed HEAD~1" $GIT reset --mixed HEAD~1

echo ""
echo -e "  ${YELLOW}--- Git: BLOCKED on main ---${NC}"
cd "$TEST_DIR/repo" && git checkout -b main 2>/dev/null || git checkout main 2>/dev/null

expect_blocked "git commit -m test (main)" $GIT commit -m "test"
expect_blocked "git push (main)" $GIT push
expect_blocked "git merge feature (main)" $GIT merge feature
expect_blocked "git pull (main)" $GIT pull
expect_blocked "git cherry-pick abc (main)" $GIT cherry-pick abc
expect_blocked "git revert HEAD (main)" $GIT revert HEAD
expect_blocked "git rebase dev (main)" $GIT rebase dev
expect_blocked "git am patch (main)" $GIT am patch
expect_blocked "git reset --hard (main)" $GIT reset --hard HEAD

# ============================================
# GIT - ALLOWED ON FEATURE BRANCHES
# ============================================
echo ""
echo -e "  ${YELLOW}--- Git: ALLOWED on feature branches ---${NC}"
cd "$TEST_DIR/repo" && git checkout -b feature/test-edge 2>/dev/null

expect_allowed "git commit -m test (feature)" $GIT commit -m "test"
expect_allowed "git commit --amend (feature)" $GIT commit --amend
expect_allowed "git commit -am test (feature)" $GIT commit -am "test"
expect_allowed "git push (feature)" $GIT push
expect_allowed "git push origin feature/test (feature)" $GIT push origin feature/test-edge
expect_allowed "git push --force (feature)" $GIT push --force
expect_allowed "git cherry-pick abc (feature)" $GIT cherry-pick abc
expect_allowed "git revert HEAD (feature)" $GIT revert HEAD
expect_allowed "git pull (feature)" $GIT pull
expect_allowed "git pull --rebase (feature)" $GIT pull --rebase
expect_allowed "git rebase main (feature)" $GIT rebase main
expect_allowed "git rebase -i HEAD~3 (feature)" $GIT rebase -i HEAD~3
expect_allowed "git merge dev (feature)" $GIT merge dev
expect_allowed "git am patch (feature)" $GIT am patch
expect_allowed "git reset --hard HEAD (feature)" $GIT reset --hard HEAD

# ============================================
# GIT - ALLOWED COMMANDS ON ANY BRANCH
# ============================================
echo ""
echo -e "  ${YELLOW}--- Git: ALLOWED commands on dev ---${NC}"
cd "$TEST_DIR/repo" && git checkout dev 2>/dev/null

expect_allowed "git status" $GIT status
expect_allowed "git log" $GIT log
expect_allowed "git log --oneline" $GIT log --oneline
expect_allowed "git diff" $GIT diff
expect_allowed "git diff --cached" $GIT diff --cached
expect_allowed "git branch" $GIT branch
expect_allowed "git branch -a" $GIT branch -a
expect_allowed "git checkout feature/test" $GIT checkout feature/test-edge
cd "$TEST_DIR/repo" && git checkout dev 2>/dev/null
expect_allowed "git checkout -b new-branch" $GIT checkout -b test-new-branch
cd "$TEST_DIR/repo" && git checkout dev 2>/dev/null
expect_allowed "git stash" $GIT stash
expect_allowed "git stash pop" $GIT stash pop
expect_allowed "git fetch" $GIT fetch
expect_allowed "git fetch origin" $GIT fetch origin
expect_allowed "git remote -v" $GIT remote -v
expect_allowed "git tag v1.0" $GIT tag v1.0
expect_allowed "git show HEAD" $GIT show HEAD
expect_allowed "git blame file.txt" $GIT blame file.txt
expect_allowed "git add ." $GIT add .
expect_allowed "git add -A" $GIT add -A
expect_allowed "git rm file" $GIT rm file
expect_allowed "git mv a b" $GIT mv a b
expect_allowed "git clean -fd" $GIT clean -fd
expect_allowed "git bisect start" $GIT bisect start
expect_allowed "git reflog" $GIT reflog
expect_allowed "git rev-parse HEAD" $GIT rev-parse HEAD
expect_allowed "git config user.name" $GIT config user.name
expect_allowed "git clone url" $GIT clone url
expect_allowed "git init" $GIT init
expect_allowed "git submodule update" $GIT submodule update
expect_allowed "git format-patch HEAD~1" $GIT format-patch HEAD~1
expect_allowed "git shortlog" $GIT shortlog
expect_allowed "git describe" $GIT describe
expect_allowed "git archive HEAD" $GIT archive HEAD
expect_allowed "git gc" $GIT gc
expect_allowed "git fsck" $GIT fsck
expect_allowed "git worktree list" $GIT worktree list

# ============================================
# GIT - EDGE CASES WITH FLAGS
# ============================================
echo ""
echo -e "  ${YELLOW}--- Git: Flag edge cases on dev ---${NC}"
cd "$TEST_DIR/repo" && git checkout dev 2>/dev/null

expect_blocked "git -c a=b -c c=d commit -m test" $GIT -c a=b -c c=d commit -m "test"
expect_blocked "git --no-pager -c x=y commit -m t" $GIT --no-pager -c x=y commit -m "t"
expect_blocked "git -C /some/path commit -m test" $GIT -C /some/path commit -m "test"
expect_blocked "git --git-dir=.git commit -m test" $GIT --git-dir=.git commit -m "test"
expect_blocked "git -c x=y -C /tmp -c z=w commit" $GIT -c x=y -C /tmp -c z=w commit -m "test"

# ============================================
# NPM - BLOCKED
# ============================================
echo ""
echo -e "  ${YELLOW}--- npm: BLOCKED ---${NC}"

expect_blocked "npm install" $NPM install
expect_blocked "npm i" $NPM i
expect_blocked "npm ci" $NPM ci
expect_blocked "npm clean-install" $NPM clean-install
expect_blocked "npm install express" $NPM install express
expect_blocked "npm i -D typescript" $NPM i -D typescript
expect_blocked "npm i --save-dev pkg" $NPM i --save-dev pkg
expect_blocked "npm install -w client" $NPM install -w client
expect_blocked "npm ci --legacy-peer-deps" $NPM ci --legacy-peer-deps

# ============================================
# NPM - ALLOWED
# ============================================
echo ""
echo -e "  ${YELLOW}--- npm: ALLOWED ---${NC}"

expect_allowed "npm run build" $NPM run build
expect_allowed "npm run dev" $NPM run dev
expect_allowed "npm run test" $NPM run test
expect_allowed "npm list" $NPM list
expect_allowed "npm ls" $NPM ls
expect_allowed "npm version" $NPM version
expect_allowed "npm version patch" $NPM version patch
expect_allowed "npm pkg get version" $NPM pkg get version
expect_allowed "npm outdated" $NPM outdated
expect_allowed "npm audit" $NPM audit
expect_allowed "npm pack" $NPM pack
expect_allowed "npm cache clean" $NPM cache clean
expect_allowed "npm config list" $NPM config list
expect_allowed "npm whoami" $NPM whoami
expect_allowed "npm info express" $NPM info express
expect_allowed "npm search express" $NPM search express
expect_allowed "npm start" $NPM start
expect_allowed "npm stop" $NPM stop
expect_allowed "npm restart" $NPM restart
expect_allowed "npm test" $NPM test
expect_allowed "npm exec something" $NPM exec something
expect_allowed "npm dedupe" $NPM dedupe
expect_allowed "npm explain express" $NPM explain express
expect_allowed "npm fund" $NPM fund
expect_allowed "npm doctor" $NPM doctor

# ============================================
# GH - BLOCKED
# ============================================
echo ""
echo -e "  ${YELLOW}--- gh: BLOCKED ---${NC}"

expect_blocked "gh pr merge" $GH pr merge
expect_blocked "gh pr merge 123" $GH pr merge 123
expect_blocked "gh pr merge --squash" $GH pr merge --squash
expect_blocked "gh pr merge --rebase" $GH pr merge --rebase
expect_blocked "gh pr merge --merge" $GH pr merge --merge
expect_blocked "gh pr merge 123 --squash" $GH pr merge 123 --squash
expect_blocked "gh pr merge --auto" $GH pr merge --auto

# ============================================
# GH - ALLOWED
# ============================================
echo ""
echo -e "  ${YELLOW}--- gh: ALLOWED ---${NC}"

expect_allowed "gh pr list" $GH pr list
expect_allowed "gh pr view" $GH pr view
expect_allowed "gh pr view 123" $GH pr view 123
expect_allowed "gh pr create" $GH pr create
expect_allowed "gh pr create --base dev" $GH pr create --base dev
expect_allowed "gh pr checkout 123" $GH pr checkout 123
expect_allowed "gh pr diff 123" $GH pr diff 123
expect_allowed "gh pr review 123" $GH pr review 123
expect_allowed "gh pr close 123" $GH pr close 123
expect_allowed "gh pr ready 123" $GH pr ready 123
expect_allowed "gh pr edit 123" $GH pr edit 123
expect_allowed "gh pr comment 123" $GH pr comment 123
expect_allowed "gh issue list" $GH issue list
expect_allowed "gh issue create" $GH issue create
expect_allowed "gh issue view 123" $GH issue view 123
expect_allowed "gh repo view" $GH repo view
expect_allowed "gh release list" $GH release list
expect_allowed "gh release create v1" $GH release create v1
expect_allowed "gh release view v1" $GH release view v1
expect_allowed "gh run list" $GH run list
expect_allowed "gh run view 123" $GH run view 123
expect_allowed "gh api repos" $GH api repos
expect_allowed "gh auth status" $GH auth status
expect_allowed "gh config get editor" $GH config get editor
expect_allowed "gh workflow list" $GH workflow list
expect_allowed "gh gist list" $GH gist list

# ============================================
# GH - EDGE CASE: "merge" not after "pr"
# ============================================
echo ""
echo -e "  ${YELLOW}--- gh: Edge cases ---${NC}"

expect_allowed "gh repo merge (not pr merge)" $GH repo merge
expect_allowed "gh merge (bare, not pr merge)" $GH merge

# ============================================
# GUARDIAN CLI
# ============================================
echo ""
echo -e "  ${YELLOW}--- Guardian CLI ---${NC}"

G="$TEST_DIR/bin/guardian"
# Create a modified guardian for testing
sed \
  -e "s|/etc/guardian|$TEST_DIR/etc/guardian|g" \
  -e "s|/usr/local/bin|$TEST_DIR/bin|g" \
  -e 's|if \[\[ "$EUID" -ne 0 \]\]; then|if false; then|g' \
  "$SCRIPT_DIR/guardian" > "$G"
chmod +x "$G"

# Test list
output=$($G list 2>&1) || true
if echo "$output" | grep -q "commit.*dev\|push.*dev"; then
  echo -e "  ${GREEN}✅ PASS${NC}: guardian list shows rules"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: guardian list"
  ((FAIL++))
fi

# Test status
output=$($G status 2>&1) || true
if echo "$output" | grep -q "Initialized"; then
  echo -e "  ${GREEN}✅ PASS${NC}: guardian status"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: guardian status"
  ((FAIL++))
fi

# Test remove with wrong password
output=$(echo "wrong" | $G remove git commit 2>&1) || true
if echo "$output" | grep -q "Wrong password"; then
  echo -e "  ${GREEN}✅ PASS${NC}: remove rejects wrong password"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: remove wrong password"
  echo "     $output"
  ((FAIL++))
fi

# Test remove with empty password
output=$(echo "" | $G remove git commit 2>&1) || true
if echo "$output" | grep -q "Wrong password"; then
  echo -e "  ${GREEN}✅ PASS${NC}: remove rejects empty password"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: remove empty password"
  echo "     $output"
  ((FAIL++))
fi

# Test remove with correct password
output=$(echo "testpass" | $G remove git commit 2>&1) || true
if echo "$output" | grep -q "Removed"; then
  echo -e "  ${GREEN}✅ PASS${NC}: remove with correct password works"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: remove correct password"
  echo "     $output"
  ((FAIL++))
fi

# Test add without message (should fail)
output=$($G add git stash 2>&1) || true
if echo "$output" | grep -q "Usage\|error message"; then
  echo -e "  ${GREEN}✅ PASS${NC}: add without message shows usage"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: add without message"
  echo "     $output"
  ((FAIL++))
fi

# Test double init
output=$($G init 2>&1) || true
if echo "$output" | grep -q "already initialized"; then
  echo -e "  ${GREEN}✅ PASS${NC}: double init blocked"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: double init"
  echo "     $output"
  ((FAIL++))
fi

# Test remove nonexistent rule
output=$(echo "testpass" | $G remove git stash 2>&1) || true
if echo "$output" | grep -q "not found\|No rules"; then
  echo -e "  ${GREEN}✅ PASS${NC}: remove nonexistent rule handled"
  ((PASS++))
else
  echo -e "  ${RED}❌ FAIL${NC}: remove nonexistent rule"
  echo "     $output"
  ((FAIL++))
fi

# ============================================
# RESULTS
# ============================================
echo ""
echo -e "  ${YELLOW}========================================${NC}"
echo -e "  ${YELLOW}    Results${NC}"
echo -e "  ${YELLOW}========================================${NC}"
echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  ${RED}Failed: $FAIL${NC}"
else
  echo -e "  Failed: 0"
fi
TOTAL=$((PASS + FAIL))
echo -e "  Total:  $TOTAL"
echo ""

# Cleanup
rm -rf "$TEST_DIR" /tmp/guardian-bins-edge

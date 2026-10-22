# End-to-end tests for LeetCode's custom judges (lc/lc-judge.h): Alt+F7 on #160, #141 and #142, whose
# examples describe how to build the lists (dot-sourced by run-all.ps1; body wrapped to keep the caller's
# variables intact). judge.test.cpp covers the judges themselves.
& {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $lcPs1 = Join-Path $repo '.zed\lc.ps1'
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('lcj-' + [guid]::NewGuid().ToString('N'))
    $journey = Join-Path $tmp 'journey'
    $cases = Join-Path $tmp 'cases'
    New-Item -ItemType Directory -Force (Join-Path $journey 'problems') | Out-Null

    function Invoke-Judge([string]$Slug, [string]$Code) {
        Copy-Item (Join-Path $repo "lc\selftest\problems\$Slug.json") (Join-Path $journey 'problems')
        $src = Join-Path $tmp "$Slug.cpp"
        [IO.File]::WriteAllText($src, $Code, $utf8)
        $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $lcPs1 -Mode test -NoWait -NoOpen -NoCommit -Offline -JourneyRoot $journey -CasesRoot $cases $src 2>&1 | Out-String
        return @{ Out = $out; Code = $LASTEXITCODE }
    }

    try {
        $r = Invoke-Judge 'intersection-of-two-linked-lists' @'
class Solution {
public:
    ListNode *getIntersectionNode(ListNode *headA, ListNode *headB) {
        ListNode *a = headA, *b = headB;
        while (a != b) { a = a ? a->next : headB; b = b ? b->next : headA; }
        return a;
    }
};
'@
        Assert-Match $r.Out "PASS  1  Intersected at '8'"
        Assert-Match $r.Out 'PASS  3  No intersection'
        Assert-Match $r.Out '3/3 passed'
        Assert-Equal $r.Code 0 "judge: #160 exit code`n$($r.Out)"

        # A node with the right value but outside the shared tail fails, as on LeetCode
        $r = Invoke-Judge 'intersection-of-two-linked-lists' @'
class Solution {
public:
    ListNode *getIntersectionNode(ListNode *headA, ListNode *headB) {
        for (ListNode *b = headB; b; b = b->next)
            for (ListNode *a = headA; a; a = a->next)
                if (a->val == b->val) return b;
        return nullptr;
    }
};
'@
        Assert-Match $r.Out "FAIL  1  got +Intersected at '5' \(a node outside the shared tail\)"
        Assert-Match $r.Out "expected Intersected at '8'"

        $r = Invoke-Judge 'linked-list-cycle' @'
class Solution {
public:
    bool hasCycle(ListNode *head) {
        ListNode *slow = head, *fast = head;
        while (fast && fast->next) { slow = slow->next; fast = fast->next->next; if (slow == fast) return true; }
        return false;
    }
};
'@
        Assert-Match $r.Out '3/3 passed'
        Assert-Equal $r.Code 0 "judge: #141 exit code`n$($r.Out)"

        $r = Invoke-Judge 'linked-list-cycle-ii' @'
class Solution {
public:
    ListNode *detectCycle(ListNode *head) {
        ListNode *slow = head, *fast = head;
        while (fast && fast->next) {
            slow = slow->next; fast = fast->next->next;
            if (slow == fast) { for (slow = head; slow != fast; slow = slow->next) fast = fast->next; return slow; }
        }
        return nullptr;
    }
};
'@
        Assert-Match $r.Out 'PASS  1  tail connects to node index 1'
        Assert-Match $r.Out 'no cycle'
        Assert-Match $r.Out '3/3 passed'
        Assert-Equal $r.Code 0 "judge: #142 exit code`n$($r.Out)"
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

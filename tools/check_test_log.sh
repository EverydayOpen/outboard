#!/usr/bin/env bash
# Reads the log of a macOS `swift test` run and fails when the real-volume tests that prove the data-loss invariants (verified copy,
# rename-not-delete, unplug and return, crash recovery) did not actually run. A skipped XCTest is not a failure to XCTest, so a job
# can stay green with all of them skipped (OUTBOARD_DISK_TESTS unset, an image that would not attach, a missing crash helper).
#   bash tools/check_test_log.sh swift.log      check a log (CI)
#   bash tools/check_test_log.sh --self-test    check the checker on synthetic logs (CI `checks` job)
# VERIFY (first macos-26 run): the XCTest line format `Test Case '-[Module.Class testName]' passed|skipped (N seconds).` that the
# patterns below rely on. If it differs, every must-pass test reports as missing: fix PASSED_LINE/SKIPPED_LINE, never the list.
# After one green run shows none of the XCTSkip calls in DiskImageLab.swift and DiskImageTests.swift fire on macos-26, turn those
# into XCTFail and this check becomes a second line of defence.
set -u

# Classes whose tests are the invariants. A skip in any of them fails, except the tests in ALLOWED_SKIPS.
CLASSES='MoveScenarioTests|GuardScenarioTests|CrashRecoveryTests|DriveFolderPlantedTests|DriveEligibilityTests'
# Skips that are legitimate on a runner: the Trash is not available in a CI session (two tests through one helper, plus the return
# test), and the ignore-ownership flag key (E9) is a VERIFY. Sparse-file and xattr skips live in other classes and are not matched.
ALLOWED_SKIPS='testReturnToMacAfterConfirmingBringsAVerifiedCopyBackAndKeepsTheDriveCopy|testACancelledCopyLeavesAFolderTheUserCanTrashAndTryAgain|testACopyThatDiedWithoutAResultLineCanBeTrashedToo|testAVolumeThatIgnoresOwnershipIsNotSilentlyAccepted'
# Tests that must be listed as passed.
MUST_PASS=(
  testASymlinkRecipeMovesAndTheLinkResolvesIntoTheDrive
  testASettingRecipeMovesAndRollsBackWithoutDeletingAnything
  testOneByteFlippedInStagingAbortsAndLeavesTheSourceAlone
  testASourceThatChangesDuringTheCopyAborts
  testADriveYankedDuringTheCopyAbortsAndLeavesTheSourceAlone
  testADriveWithOutboardAsALinkIsRefusedAndNothingIsWrittenThroughIt
  testAReadOnlyAttachIsRefused
  testEjectParksAndACleanReturnReconnectsAfterTheSample
  testAPulledDriveStaysDisconnectedUntilCheckAndReconnect
  testTheProcessDiesAtEveryJournalRecordAndRecoveryLeavesTheDataSafe
)
SKIPPED_LINE="Test Case .*($CLASSES).* skipped"

check_log() {   # check_log LOG: prints one line per problem
  local log=$1 t
  [ -s "$log" ] || { echo "$log: empty or missing"; return; }
  grep -F 'Disk image tests run only with' "$log" | head -1 | sed 's/^/OUTBOARD_DISK_TESTS did not reach the tests: /'
  grep -E "$SKIPPED_LINE" "$log" | grep -vE "$ALLOWED_SKIPS" | sed 's/^/skipped invariant test: /'
  for t in "${MUST_PASS[@]}"; do
    grep -qE "Test Case .*$t.* passed" "$log" || echo "not listed as passed: $t"
  done
}

if [ "${1:-}" = "--self-test" ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  line() { printf "Test Case '-[OutboardMacTests.%s %s]' %s (0.1 seconds).\n" "$1" "$2" "$3"; }
  good() { for t in "${MUST_PASS[@]}"; do line MoveScenarioTests "$t" passed; done; }
  { good; line MoveScenarioTests testReturnToMacAfterConfirmingBringsAVerifiedCopyBackAndKeepsTheDriveCopy skipped; line VerifierTests testX skipped; } > "$T/ok.log"
  { good; line GuardScenarioTests testSomethingNew skipped; } > "$T/skip.log"
  { good; echo 'Disk image tests run only with OUTBOARD_DISK_TESTS=1.'; } > "$T/env.log"
  good | grep -v testAReadOnlyAttachIsRefused > "$T/missing.log"
  : > "$T/empty.log"
  rc=0
  [ -z "$(check_log "$T/ok.log")" ] || { echo "self-test: flagged a clean log"; check_log "$T/ok.log"; rc=1; }
  for x in skip env missing empty; do [ -n "$(check_log "$T/$x.log")" ] || { echo "self-test: missed $x"; rc=1; }; done
  [ "$rc" -eq 0 ] && echo "check_test_log: self-test ok"
  exit $rc
fi

[ $# -eq 1 ] || { echo "usage: check_test_log.sh LOG | --self-test"; exit 2; }
out=$(check_log "$1")
if [ -n "$out" ]; then
  echo "$out"
  echo "::error::The real-volume tests did not all run (see tools/check_test_log.sh)"
  exit 1
fi
echo "check_test_log: the invariant tests ran"

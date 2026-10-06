#!/usr/bin/env python3
"""Exercise signing decisions with synthetic identities, without reading a real Keychain."""
import pathlib
import subprocess
import unittest

HELPER = pathlib.Path(__file__).with_name("signing_identity.sh")
A, B = "A" * 40, "B" * 40
IDENTITIES = f'1) {B} "Apple Development: Other"\n2) {A} "Apple Development: Original"'


def call(function, *args):
    return subprocess.run(
        ["bash", "-c", 'source "$1"; shift; "$@"', "bash", str(HELPER), function, *args],
        capture_output=True, text=True, check=False,
    )


class SigningIdentityTests(unittest.TestCase):
    def test_rebuild_keeps_pinned_identity_despite_list_order(self):
        result = call("burro_signing_identity", "", A, IDENTITIES, "yes")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), A)

    def test_missing_saved_identity_never_falls_back(self):
        for identities in ["", f'1) {B} "Apple Development: Other"']:
            result = call("burro_signing_identity", "", A, identities, "yes")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_installed_trusted_app_cannot_downgrade_without_pin_file(self):
        self.assertNotEqual(call("burro_signing_identity", "", "", "", "yes").returncode, 0)

    def test_fresh_source_and_ci_builds_can_use_ad_hoc(self):
        result = call("burro_signing_identity", "", "", "", "no")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "-")

    def test_explicit_choice_remains_possible(self):
        for choice in [A, "-", "Apple Development: Original"]:
            result = call("burro_signing_identity", choice, B, "", "yes")
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), choice)

    def test_same_requirement_survives_binary_changes(self):
        value = "designated => identifier Burro and anchor apple generic"
        self.assertEqual(call("burro_check_signing_requirement", value, value, "yes", "").returncode, 0)

    def test_implicit_requirement_change_is_rejected(self):
        self.assertNotEqual(call("burro_check_signing_requirement", "designated => old", "designated => new", "yes", "").returncode, 0)
        self.assertEqual(call("burro_check_signing_requirement", "designated => old", "designated => new", "yes", B).returncode, 0)
        self.assertNotEqual(call("burro_check_signing_requirement", "", "", "no", "").returncode, 0)


if __name__ == "__main__":
    unittest.main()

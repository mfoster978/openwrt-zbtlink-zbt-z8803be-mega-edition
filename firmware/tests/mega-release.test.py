"""Build-host metadata checks. No network access or router commands."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("mega_release", Path(__file__).resolve().parents[1] / "scripts/mega-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.image = Path(self.temp.name) / (release.IMAGE_PREFIX + "firmware-42.1.bin")
        self.image.write_bytes(b"test-image" * 110000)
        self.sha = "a" * 40
        with patch.object(release, "git", side_effect=[self.sha, ""]):
            self.build = release.identity(Path("/fixture"), "firmware-42.1")

    def create(self, **kwargs):
        return release.manifest(kwargs.get("build", self.build), kwargs.get("image", self.image),
                                kwargs.get("version", "firmware-42.1"), kwargs.get("sha", self.sha))

    def test_identity_and_manifest(self):
        manifest = self.create()
        self.assertEqual(manifest["image"]["sha256"], release.hashlib.sha256(self.image.read_bytes()).hexdigest())
        self.assertEqual(manifest["image"]["size"], 1100000)
        self.assertEqual(manifest["variant"], "mega")
        self.assertEqual(manifest["repository"], "mfoster978/OpenWrt-ZBT-Z8803BE-Mega")

    def test_container_git_trust_is_scoped_to_recipe_checkout(self):
        root = Path(self.temp.name).resolve()
        with patch.object(release.subprocess, "check_output", return_value=self.sha + "\n") as run:
            self.assertEqual(release.git(root, "rev-parse", "HEAD"), self.sha)
        run.assert_called_once_with([
            "git", "-c", "safe.directory=" + str(root), "-C", str(root), "rev-parse", "HEAD"
        ], text=True)

    def test_local_identity_does_not_claim_release_version(self):
        with patch.object(release, "git", side_effect=[self.sha, " M firmware/example"]):
            build = release.identity(Path("/fixture"))
        self.assertEqual(build["version"], "local-" + self.sha[:12])
        self.assertTrue(build["dirty"])

    def test_dirty_release_rejected(self):
        with patch.object(release, "git", side_effect=[self.sha, "?? firmware/new"]):
            with self.assertRaises(ValueError):
                release.identity(Path("/fixture"), "firmware-42.1")

    def test_timestamp_release_supports_local_and_actions_builds(self):
        version = "firmware-202609100700.1"
        with patch.object(release, "git", side_effect=[self.sha, ""]):
            build = release.identity(Path("/fixture"), version)
        image = self.image.with_name(release.IMAGE_PREFIX + version + ".bin")
        image.write_bytes(self.image.read_bytes())
        self.assertEqual(self.create(build=build, image=image, version=version)["version"], version)

    def test_wrong_variant_board_repo_or_identity_rejected(self):
        for field, value in (("variant", "minimal"), ("repository", "other/repo"),
                             ("board", "openwrt,one"), ("schema", 2),
                             ("source_sha", "b" * 40), ("version", "firmware-41.1"),
                             ("dirty", True), ("built_at", "")):
            with self.subTest(field=field):
                build = copy.deepcopy(self.build)
                build[field] = value
                with self.assertRaises(ValueError):
                    self.create(build=build)

    def test_missing_dirty_state_rejected(self):
        del self.build["dirty"]
        with self.assertRaises(ValueError):
            self.create()

    def test_untrusted_release_version_rejected(self):
        for value in ("latest", "../../firmware-42.1", "firmware-42.1\n", "firmware-0.1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.create(version=value)

    def test_wrong_image_type_empty_image_and_symlink_rejected(self):
        other = self.image.with_name("openwrt-zbt-z8803be-initramfs-kernel.bin")
        other.write_bytes(self.image.read_bytes())
        with self.assertRaises(ValueError):
            self.create(image=other)
        self.image.unlink()
        self.image.symlink_to(other)
        with self.assertRaises(ValueError):
            self.create()
        self.image.unlink()
        self.image.touch()
        with self.assertRaises(ValueError):
            self.create()


if __name__ == "__main__":
    unittest.main()

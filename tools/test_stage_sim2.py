"""Local source-level tests; these do not substitute for BusyBox/UCI fixtures."""
import hashlib
import json
import unittest

import stage_sim2 as stage


class Sim2SourceTests(unittest.TestCase):
    def setUp(self):
        self.sources = {
            name: (stage.ORIGINAL / name).read_text(encoding="utf-8")
            for name in stage.TRANSFORMS
        }
        self.outputs = {
            name: transform(self.sources[name])
            for name, transform in stage.TRANSFORMS.items()
        }

    def output(self, suffix):
        return next(text for name, text in self.outputs.items() if name.endswith(suffix))

    def test_manifest_matches_original_and_staged_bytes(self):
        manifest = json.loads((stage.STAGED / "manifest.json").read_text())
        for name, entry in manifest.items():
            for root, key in ((stage.ORIGINAL, "original_sha256"),
                              (stage.STAGED, "staged_sha256")):
                self.assertEqual(hashlib.sha256((root / name).read_bytes()).hexdigest(),
                                 entry[key])

    def test_staged_outputs_match_reviewed_transformations(self):
        for name, text in self.outputs.items():
            self.assertEqual((stage.STAGED / name).read_bytes(), text.encode())

    def test_source_anchor_missing_or_duplicate_fails(self):
        for text in ("missing token", "anchor anchor"):
            with self.assertRaises(ValueError):
                stage.replace_once(text, "anchor", "replacement")

    def test_watchdog_maps_actual_second_slot(self):
        text = self.output("watchdog-loop")
        self.assertIn("2_1) printf '%s\\n' 5g2", text)
        self.assertIn("case \"$sec\" in 4_1|2_1)", text)
        self.assertNotIn("4_2", text)

    def test_usb_hotplug_maps_actual_second_slot(self):
        text = self.output("autoenable")
        self.assertIn("2-1) section=2_1; power=5g2", text)
        self.assertIn("4-1) section=4_1; power=5g1", text)
        self.assertNotIn("section=4_2", text)

    def test_device_resolution_has_no_enumeration_fallback(self):
        for suffix in ("watchdog-loop", "autoenable"):
            text = self.output(suffix)
            self.assertIn("path=/sys/bus/usb/devices/2-1", text)
            self.assertIn("path=/sys/bus/usb/devices/4-1", text)
            self.assertIn('[ "$count" = 1 ] || return 1', text)
            self.assertIn('[ "${driver##*/}" = qmi_wwan ]', text)
            self.assertIn('device="$(physical_device 2_1)"', text)

    def test_metric_is_validated_and_not_forced(self):
        for suffix in ("watchdog-loop", "autoenable"):
            text = self.output(suffix)
            self.assertIn("configured_metric", text)
            self.assertIn('"${#value}" -le 5', text)
            self.assertIn('"$value" -le 65535', text)
            self.assertNotIn("metric=200", text)
            self.assertNotIn('metric" 200', text)

    def test_only_sim2_ownership_added(self):
        self.assertIn('if [ "$sec" = 2_1 ]; then\n\t\tfor iface',
                      self.output("watchdog-loop"))
        self.assertIn('if [ "$section" = 2_1 ]; then\n\t\tset_q',
                      self.output("autoenable"))

    def test_ipv6_disabled_remains_in_both_writers(self):
        self.assertIn("${sec}v6.disabled=1", self.output("watchdog-loop"))
        self.assertIn('network.${section}v6.disabled" 1', self.output("autoenable"))

    def test_led_slot_identification_is_exact(self):
        hotplug = self.output("20-zbt-modem-led")
        self.assertIn('\t4-1)\n\t\tLED="/sys/class/leds/blue:mobile-1"', hotplug)
        self.assertIn('\t2-1)\n\t\tLED="/sys/class/leds/blue:mobile-2"', hotplug)
        self.assertNotIn("\t*-1)\n", hotplug)
        self.assertIn("1:4-1|2:2-1)", self.output("zbt-modem-led-poller"))

    def test_sim2_does_not_gain_an_at_client(self):
        text = self.output("zbt-modem-led-poller")
        self.assertIn('if [ "$slot" = 2 ]; then\n\t\t\tSLOT_STATE=no_signal\n'
                      '\t\t\tSLOT_KEY=no_signal\n\t\t\treturn\n\t\tfi\n'
                      '\t\tSLOT_PORT=$(slot_at_port', text)

    def test_offline_state_is_nonactivating(self):
        helper = stage.offline_helper()
        for key in ("2_1.auto=0", "2_1.disabled=1", "2_1.defaultroute=0",
                    "2_1v6.auto=0", "2_1v6.disabled=1", "2_1v6.defaultroute=0"):
            self.assertIn(key, helper)
        for command in ("/etc/init.d/", "ifup ", "fw4 ", "sms_tool "):
            self.assertNotIn(command, helper)
        self.assertNotIn('set "qmodem.', helper)

    def test_sim2_returns_before_legacy_runtime_writes(self):
        watchdog = self.output("watchdog-loop")
        self.assertLess(watchdog.index('prepare_sim2_offline\n\t\treturn 1'),
                        watchdog.index('printf 1 >'))
        hotplug = self.output("autoenable")
        self.assertLess(hotplug.index('prepare_sim2_offline\n\t\texit 0'),
                        hotplug.index('set_q "qmodem.$section.state"'))

    def test_generation_is_deterministic(self):
        for name, transform in stage.TRANSFORMS.items():
            self.assertEqual(transform(self.sources[name]), self.outputs[name])


if __name__ == "__main__":
    unittest.main(verbosity=2)

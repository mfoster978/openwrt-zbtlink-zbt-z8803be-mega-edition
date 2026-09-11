# Live router speed tests

**Mega Edition**, developed and maintained by Michael Foster / @mfoster978, replaces the former small interactive Cloudflare sample with a live dashboard under **Services → Speed Test Utility**. The Minimal edition deliberately remains without speed testing.

## What is measured

- The router transfers actual data to/from servers in the Speedtest.net directory. The engine is the MIT-licensed [speedtest-go v1.8.3 library](https://github.com/showwin/speedtest-go/tree/v1.8.3), with its source archive SHA-256 pinned in the package and tests. This release includes upstream upload-confirmation, adaptive-concurrency and upload-redirect repairs absent from the former v1.7.10 engine.
- Up to sixteen concurrent connections measure download and upload in separate phases, each with a maximum 20-second capture window. The newer engine adapts active upload workers based on server-confirmed progress. The longer test gives high-latency 5G links time to ramp up; this is not the reduced-accuracy saving mode.
- The dial and graph use the library's real throughput callbacks, captured every 250 ms. LuCI requests the newest authenticated snapshot at the same 250 ms cadence with only one request in flight. The needle smoothly transitions between measured values; numbers do not advance without another measured event. Mbps is decimal megabits/second, converted from the engine's bytes/second by multiplying by 8 / 1,000,000.
- Download/upload result cards retain the engine's stabilized final rates. Ping and jitter are measured HTTP round-trip timing to the test server, not cellular RF signal quality, ICMP ping, or loaded latency. Unmeasured values display a dash, not an invented zero.
- Automatic selection starts with the lowest-latency reachable entries and sends a small 32 KiB upload-capability probe. If an entry supports latency/download but rejects upload traffic, the engine tries the next candidate (up to eight) before the full measurement begins. **Find nearby servers** retrieves choices without bulk transfers; a numeric Speedtest.net server ID can also be entered. The selected sponsor, location and server ID remain visible with the results.
- These are real measurements using Speedtest.net servers, **not the official Ookla client, branding, methodology or an official shareable Speedtest.net result**. Results can differ from the website or official app. The independent-client attribution is visible in the page.

## Cellular and routing safeguards

The test is initiated on the **router**, not in the phone/browser. It measures the router's chosen Internet path, not the client's Wi-Fi link. Other traffic, CPU limitations, carrier policy, server capacity, and VPN/Speedify routing affect results.

Connection choices are current default route, wired WAN, SFP WAN, USB phone tether, Modem 1 / 5G1 and Modem 2 / 5G2. Modems are resolved from physical USB paths `4-1` and `2-1`, not enumeration order. Wired and USB-tether selections resolve their live OpenWrt L3 device. Both the source address and Linux `SO_BINDTODEVICE` are used, so overlapping modem private IPs do not cause silent fallback. The process stops if the selected device disappears or its ifindex changes. DNS uses the router's normal resolver; VPN and policy routing still require consideration when interpreting the path.

**A full test can use hundreds of MB or exceed 1 GB.** There is no 30 MB cap on this interactive test. On first use in a browser, GO opens a terms/data-use confirmation and accepting it launches automatic server selection. Acceptance is remembered locally in that browser; the visible checkbox can clear or restore it. The backend independently requires confirmation on every start request. Running a test can saturate the connection and affect other users.

- Stop requests are restricted to the current, unguessable run ID and end only that test process. A process-level supervisor stops cancelled tests even if a library call ignores cancellation. There is a 90-second hard deadline for the entire operation.
- A shared, uptime-based 120-second lease prevents interactive tests overlapping the existing background MultiWAN sampler. Lost/expired workers are reported as errors and can be retried; late callbacks cannot turn a cancelled result into success.
- Per-run snapshots, samples and cancellation markers live in RAM, not persistent router flash. Only the current result is retained; it is lost on reboot.
- No modem power, APN, SIM, TTL, firewall, failover preference or VPN settings are changed. Existing traffic/default-route choices are preserved.
- HTTPS server-discovery certificates are verified. Normal server redirects are followed without disabling TLS verification. The library can use the server's HTTP transfer endpoint; this is synthetic benchmark traffic, not private user content.
- Non-2xx responses and HTML/error-page transfer bodies are rejected. Compatible servers legitimately return several different short acknowledgement bodies, including an empty 2xx response, so the engine validates the completed POST and response status instead of requiring one vendor-specific text string. A failed phase produces an explicit error rather than a fabricated complete result.

The background **MultiWAN → Speed & Recovery** checker remains the separately documented bounded Cloudflare sampler, with its existing thresholds and data limits. Interactive results do not change failover policy.

## Validation and rollout

`firmware/tests/check-speedtest.sh` verifies the exact library source hash, runs adapter tests including actual controlled loopback download/upload transfers, checks RPC argument types and session handling, and builds a static Linux ARM64 executable. Tests include slot isolation, USB-tether validation, lease ownership, cancellation/deadline process exit, unit conversion, redirects, server error rejection, varied valid upload acknowledgements and automatic fallback from an upload-incompatible server. They do not consume public-network speed-test bandwidth.

`firmware/tests/speedtest-ui.cjs` checks the actual LuCI view in Chromium at desktop and phone widths using clearly isolated RPC fixtures: live gauge/chart, non-simulated readings, modem/server selection, data consent, cancellation, errors and final results. No Save/Apply controls or unauthenticated CGI endpoint are used. The Sanity workflow runs both suites. Firmware builds require the engine in the resolved configuration and image manifest, and check the installed binary, view and stylesheet.

After installing the new firmware, open LuCI in a refreshed browser tab, run the test on each connected modem independently, and verify the selected physical interface. Compare several reachable servers. This still requires an on-router test with the user's carriers; host tests cannot certify actual cellular throughput.

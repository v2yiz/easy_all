# Historical Debug Session: gcore-xhttp-timeout
- **Status**: [CLOSED - GCORE XHTTP REMOVED]
- **Issue**: Gcore HTTPS health and WebSocket pass, but the XHTTP packet-up probe times out after 30 seconds with no response.
- **Debug Server**: http://10.88.254.52:7777/event
- **Log File**: `.dbg/trae-debug-log-gcore-xhttp-timeout.ndjson`

## Reproduction Steps
1. Deploy the current `dev` or `main` build to the Gcore VPS.
2. Run `sudo easy_all apply-cloud`.
3. Observe `HTTPS=200`, `WebSocket=ok`, and `XHTTP=failed(curl=28,HTTP=000)`.

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | Gcore does not complete the current XHTTP packet-up request/response flow | Low | Medium | Rejected as sole cause: direct origin fails with the same HTTP 400 |
| B | Nginx forwards XHTTP to Xray with the wrong upstream protocol | Low | Medium | Rejected: direct loopback XHTTP reproduces the failure without Nginx |
| C | Gcore buffers or blocks the XHTTP POST stream before it reaches the origin | Low | Medium | Rejected: failure is immediate and reproduced without Gcore |
| D | The external `cp.cloudflare.com` probe target causes a false negative | Low | Low | Rejected: XHTTP setup fails before the target connection is established |
| E | Xray client/server XHTTP parameters differ | High | Low | Confirmed: client `extra` replaces outer XHTTP options, so its outer `xPaddingBytes` is ignored and defaults to 100-1000 while the server accepts only 100-500 |

## Log Evidence
- Pre-fix user log: Resource `active`, certificate `DONE`, public health HTTP `200`.
- Pre-fix user log: WebSocket probe succeeds.
- Pre-fix user log: XHTTP SOCKS accepts the outbound request, then curl times out after 30 seconds with zero bytes.
- User selected manual diagnostics; network-reporting instrumentation was removed and will not be pushed.
- Manual CDN probe: HTTP 400 in 0.18 seconds.
- Manual direct-origin probe: HTTP 400 in 0.05 seconds.
- Server journal: no `vless-xhttp-h2-in` acceptance during either probe.
- Direct health without client certificate returns Nginx 400; with the certificate it returns 200, so mTLS is healthy.
- A request to the XHTTP path returns 400 with the Xray `x-padding` header, proving that routing reaches the XHTTP handler.
- Nginx records `upstream prematurely closed connection` for the HTTP/1.1 upstream.
- The official Xray `VLESS-XHTTP3-Nginx` example uses `grpc_pass` between Nginx and the XHTTP inbound.
- A `grpc_pass` test still returns 400 before reaching the VLESS inbound; that proposed fix is rejected.
- A direct `security:none` XHTTP probe to `127.0.0.1:10086` returns HTTP 400 in 27ms.
- Xray 26.3.27 source returns HTTP 400 when request padding is outside the server range.
- The server config sets `xPaddingBytes` to `100-500`, while `gcore_probe_xhttp` omits it and therefore uses Xray's `100-1000` default.
- A direct probe with outer `xPaddingBytes:"100-500"` and `extra:{uplinkHTTPMethod:"POST"}` still returns HTTP 400 because Xray replaces the outer XHTTP options with `extra`; only outer `host`, `path`, and `mode` are copied into the replacement.
- The direct probe server logs `invalid padding (queryInHeader=Referer, key=x_padding) length:565`, proving the client used the 100-1000 default and the server rejected a value above 500.

## Verification Conclusion
The failure occurs during XHTTP padding validation, before VLESS handles the proxied destination. Gcore, mTLS, Nginx, and `cp.cloudflare.com` are not the cause. The managed server range `100-500` is incompatible with the Xray and Mihomo client default `100-1000`.

## Historical Attempted Fix
- Restore the Gcore XHTTP server range to `100-1000`, matching the client default and the Cloudflare profile.
- This was tested before the final WebSocket-only architecture decision below.

## Final Architecture Decision

Gcore now exposes only VLESS over WebSocket. The XHTTP inbound, Nginx path,
client configuration and deployment probe were removed because they were not
published in subscriptions and could incorrectly block an otherwise healthy
WebSocket deployment. This file is retained only as historical debugging
evidence; its fix instructions no longer apply to the current code.

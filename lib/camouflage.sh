#!/usr/bin/env bash

# Reality 伪装站多模板生成与受管文件回收。
# 独立可测：未加载 log.sh 时自动引入，路径与状态目录可通过环境变量覆盖。

CAMOUFLAGE_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
if ! declare -F die >/dev/null 2>&1; then
    # shellcheck source=lib/log.sh
    source "${CAMOUFLAGE_LIB_DIR}/log.sh"
fi

: "${CAMOUFLAGE_DIR:=/var/www/easy_all/camouflage}"
: "${STATE_DIR:=/etc/easy_all}"

camouflage_managed_manifest_file() {
    printf '%s/camouflage-managed.list\n' "${STATE_DIR}"
}

camouflage_rand_index() {
    local count=$1 hex
    hex=$(openssl rand -hex 2) || die "生成伪装站随机种子失败"
    printf '%d\n' "$((16#${hex} % count))"
}

camouflage_deploy_site() {
    # 幂等且非破坏性：已有非空 index.html 时保留原实例变体或用户自定义站点。
    [[ ! -s "${CAMOUFLAGE_DIR}/index.html" ]] || return 0

    local archetype template brand brand_initial domain contact_user contact_email
    local accent accent_hover radius svg_rx css_hex build_id year
    local title subtitle tagline footer_note manifest p file
    local -a archetypes=(login status docs studio)
    local -a brands=(
        "Alder Works" "Beacon Studio" "Cinder Labs" "Crestline Data"
        "Fieldstone IO" "Harbor Desk" "Kestrel Systems" "Linden Cloud"
        "Meridian Ops" "Northstar Platform" "Oakridge Compute" "Pebble Software"
        "Quarry Metrics" "Solstice Dev" "Strata Foundry" "Trellis Workspace"
    )
    local -a accents=(
        "#2563eb" "#4f46e5" "#0d9488" "#059669"
        "#0284c7" "#334155" "#b45309" "#6d28d9"
    )
    local -a accent_hovers=(
        "#1d4ed8" "#4338ca" "#0f766e" "#047857"
        "#0369a1" "#1e293b" "#92400e" "#5b21b6"
    )
    local -a radii=("6px" "8px" "10px" "12px")
    local -a svg_radii=("12" "14" "16" "18")
    local -a contact_users=("support" "ops")
    local -a subtitles=()
    local -a titles=()
    local -a managed=()
    local palette_idx radius_idx

    case "${EASY_ALL_CAMOUFLAGE_TEMPLATE:-}" in
    login | status | docs | studio) archetype="${EASY_ALL_CAMOUFLAGE_TEMPLATE}" ;;
    *) archetype=${archetypes[$(camouflage_rand_index "${#archetypes[@]}")]} ;;
    esac

    template="${CAMOUFLAGE_LIB_DIR}/../templates/camouflage-${archetype}.html"
    [[ -s "${template}" ]] || die "缺少伪装站页面模板：${template}"

    brand=${brands[$(camouflage_rand_index "${#brands[@]}")]}
    brand_initial=${brand:0:1}
    palette_idx=$(camouflage_rand_index "${#accents[@]}")
    accent=${accents[palette_idx]}
    accent_hover=${accent_hovers[palette_idx]}
    radius_idx=$(camouflage_rand_index "${#radii[@]}")
    radius=${radii[radius_idx]}
    svg_rx=${svg_radii[radius_idx]}
    css_hex=$(openssl rand -hex 2) || die "生成伪装站样式前缀失败"
    build_id=$(openssl rand -hex 3) || die "生成伪装站构建标识失败"
    year=$(date +%Y)
    domain=${DIRECT_DOMAIN:-portal.internal}
    contact_user=${contact_users[$(camouflage_rand_index "${#contact_users[@]}")]}
    contact_email="${contact_user}@${domain}"
    p="--ui-${css_hex}"

    case "${archetype}" in
    login)
        title="Workspace Sign In"
        subtitles=(
            "Sign in with your organization account to continue."
            "Authenticate to access your team workspace and settings."
            "Enter your work credentials to open the member console."
        )
        subtitle=${subtitles[$(camouflage_rand_index "${#subtitles[@]}")]}
        tagline="Single sign-on and directory access for internal teams."
        footer_note="Contact your workspace administrator if you cannot sign in."
        ;;
    status)
        title="System Status"
        subtitles=(
            "Live availability and scheduled maintenance across core regions."
            "Real-time telemetry for public endpoints and background services."
            "Current operational status and historical uptime reporting."
        )
        subtitle=${subtitles[$(camouflage_rand_index "${#subtitles[@]}")]}
        tagline="Automated health checks updated every 60 seconds."
        footer_note="Subscribe to maintenance notices via your operations contact."
        ;;
    docs)
        title="Developer Documentation"
        subtitles=(
            "API references, authentication guides, and event schemas."
            "Integration guides, REST endpoints, and webhook specifications."
            "Everything you need to build and automate with our platform API."
        )
        subtitle=${subtitles[$(camouflage_rand_index "${#subtitles[@]}")]}
        tagline="Versioned HTTP API with predictable JSON responses."
        footer_note="Need integration assistance? Reach out to our developer desk."
        ;;
    studio)
        titles=(
            "Reliable Infrastructure for Modern Teams"
            "Cloud Tooling Built for Predictable Operations"
            "Minimal Systems Engineering at Production Scale"
        )
        subtitles=(
            "We design resilient compute, telemetry, and delivery platforms for engineering teams."
            "Independent software studio focused on observable services and dependable deployments."
            "Practical cloud architecture and managed developer platforms without unnecessary complexity."
        )
        title=${titles[$(camouflage_rand_index "${#titles[@]}")]}
        subtitle=${subtitles[$(camouflage_rand_index "${#subtitles[@]}")]}
        tagline="Operated globally with deterministic releases and transparent SLOs."
        footer_note="Private infrastructure inquiries are welcome via email."
        ;;
    esac

    install -d -m 0755 "${CAMOUFLAGE_DIR}" "${CAMOUFLAGE_DIR}/assets" \
        || die "创建伪装站目录失败：${CAMOUFLAGE_DIR}"
    if [[ "${archetype}" == "login" ]]; then
        install -d -m 0755 "${CAMOUFLAGE_DIR}/login" \
            || die "创建伪装站登录目录失败：${CAMOUFLAGE_DIR}/login"
    fi

    cat >"${CAMOUFLAGE_DIR}/assets/site.css" <<EOF
/* ${brand} stylesheet — build ${build_id} */
:root {
  color-scheme: light dark;
  ${p}-accent: ${accent};
  ${p}-accent-hover: ${accent_hover};
  ${p}-bg: #f5f7fa;
  ${p}-surface: #ffffff;
  ${p}-surface-alt: #f8fafc;
  ${p}-text: #0f172a;
  ${p}-muted: #475569;
  ${p}-border: #e2e8f0;
  ${p}-ok: #15803d;
  ${p}-ok-bg: #dcfce7;
  ${p}-err: #b91c1c;
  ${p}-err-bg: #fee2e2;
  ${p}-code-bg: #f1f5f9;
  ${p}-radius: ${radius};
  ${p}-shadow: 0 8px 24px rgba(15, 23, 42, 0.08);
}
@media (prefers-color-scheme: dark) {
  :root {
    ${p}-bg: #0b1120;
    ${p}-surface: #111827;
    ${p}-surface-alt: #1e293b;
    ${p}-text: #f1f5f9;
    ${p}-muted: #94a3b8;
    ${p}-border: #243044;
    ${p}-ok: #4ade80;
    ${p}-ok-bg: rgba(34, 197, 94, 0.16);
    ${p}-err: #fca5a5;
    ${p}-err-bg: rgba(239, 68, 68, 0.16);
    ${p}-code-bg: #1e293b;
    ${p}-shadow: 0 10px 28px rgba(0, 0, 0, 0.35);
  }
}
*, *::before, *::after { box-sizing: border-box; }
body {
  margin: 0;
  min-height: 100vh;
  background: var(${p}-bg);
  color: var(${p}-text);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
}
a { color: var(${p}-accent); text-decoration: none; }
a:hover { text-decoration: underline; }
code, pre {
  font-family: "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace;
}
code {
  padding: 2px 6px;
  font-size: 0.88em;
  background: var(${p}-code-bg);
  border-radius: 4px;
}
pre {
  margin: 14px 0;
  padding: 14px 16px;
  overflow-x: auto;
  background: var(${p}-code-bg);
  border: 1px solid var(${p}-border);
  border-radius: var(${p}-radius);
  font-size: 13px;
  line-height: 1.5;
}
pre code { padding: 0; background: transparent; }
.shell { width: 100%; max-width: 960px; margin: 0 auto; padding: 0 20px; }
.topbar {
  background: var(${p}-surface);
  border-bottom: 1px solid var(${p}-border);
}
.topbar-inner {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  min-height: 60px;
}
.brand, .brand-row {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  font-weight: 600;
  color: var(${p}-text);
}
.brand:hover { text-decoration: none; }
.brand-mark {
  display: inline-block;
  width: 12px;
  height: 12px;
  border-radius: 3px;
  background: var(${p}-accent);
  flex-shrink: 0;
}
.domain-pill, .version-pill {
  padding: 2px 8px;
  font-size: 12px;
  font-weight: 500;
  color: var(${p}-muted);
  background: var(${p}-surface-alt);
  border: 1px solid var(${p}-border);
  border-radius: 999px;
}
.nav { display: flex; flex-wrap: wrap; gap: 18px; font-size: 14px; }
.nav a { color: var(${p}-muted); }
.nav a:hover { color: var(${p}-text); text-decoration: none; }
.main-stack {
  display: flex;
  flex-direction: column;
  gap: 24px;
  padding-top: 32px;
  padding-bottom: 48px;
}
.hero { padding: 12px 0 4px; }
.hero-compact { display: flex; flex-direction: column; gap: 10px; }
.eyebrow {
  margin: 0 0 8px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(${p}-accent);
}
h1 { margin: 0 0 8px; font-size: 28px; line-height: 1.25; font-weight: 650; }
h2 { margin: 0 0 10px; font-size: 18px; line-height: 1.3; font-weight: 600; }
h3 { margin: 0 0 6px; font-size: 15px; font-weight: 600; }
.subtitle { margin: 0; font-size: 15px; color: var(${p}-muted); max-width: 66ch; }
.meta-line { margin: 8px 0 0; font-size: 13px; color: var(${p}-muted); }
.muted { font-size: 13px; color: var(${p}-muted); }
.row-desc { margin: 4px 0 0; font-size: 14px; color: var(${p}-muted); }
.card {
  background: var(${p}-surface);
  border: 1px solid var(${p}-border);
  border-radius: var(${p}-radius);
  padding: 24px;
  box-shadow: var(${p}-shadow);
}
.subcard {
  padding: 16px;
  background: var(${p}-surface-alt);
  border: 1px solid var(${p}-border);
  border-radius: var(${p}-radius);
}
.section-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 14px;
}
.section-head h2 { margin: 0; }
.grid-2 { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
.grid-3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; }
.action-row { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 20px; }
.btn-primary, .btn-secondary {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 10px 16px;
  font-size: 14px;
  font-weight: 600;
  border-radius: var(${p}-radius);
  border: 1px solid transparent;
  cursor: pointer;
}
.btn-primary {
  width: 100%;
  color: #ffffff;
  background: var(${p}-accent);
}
.btn-primary:hover { background: var(${p}-accent-hover); text-decoration: none; }
.btn-primary:disabled { opacity: 0.65; cursor: wait; }
.btn-secondary {
  color: var(${p}-text);
  background: var(${p}-surface);
  border-color: var(${p}-border);
}
.btn-secondary:hover { background: var(${p}-surface-alt); text-decoration: none; }
.btn-inline { width: auto; }
.text-link { display: inline-block; margin-top: 10px; font-size: 13px; font-weight: 600; }
.page-auth, .page-error {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px;
}
.auth-wrap, .error-wrap { width: 100%; max-width: 410px; }
.auth-card { padding: 30px; }
.auth-header { margin-bottom: 22px; }
.auth-header h1 { margin-top: 14px; font-size: 22px; }
.auth-form { display: flex; flex-direction: column; gap: 14px; }
.field { display: flex; flex-direction: column; gap: 6px; }
.field label { font-size: 13px; font-weight: 500; }
.field input {
  width: 100%;
  padding: 10px 12px;
  font-size: 14px;
  color: var(${p}-text);
  background: var(${p}-surface);
  border: 1px solid var(${p}-border);
  border-radius: var(${p}-radius);
}
.field input:focus {
  outline: 2px solid var(${p}-accent);
  outline-offset: 1px;
}
.alert {
  padding: 10px 12px;
  font-size: 13px;
  border-radius: var(${p}-radius);
}
.alert-error {
  color: var(${p}-err);
  background: var(${p}-err-bg);
}
.auth-hint { margin: 16px 0 0; font-size: 12px; color: var(${p}-muted); }
.auth-footer {
  margin-top: 18px;
  text-align: center;
  font-size: 12px;
  color: var(${p}-muted);
}
.auth-footer p { margin: 4px 0; }
.status-banner {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 20px 24px;
  background: var(${p}-surface);
  border: 1px solid var(${p}-border);
  border-radius: var(${p}-radius);
  box-shadow: var(${p}-shadow);
}
.status-banner h1 { margin: 0 0 2px; font-size: 22px; }
.dot { width: 12px; height: 12px; border-radius: 50%; flex-shrink: 0; }
.dot-ok { background: var(${p}-ok); }
.service-list, .log-list { list-style: none; margin: 0; padding: 0; }
.service-row, .log-item {
  padding: 14px 0;
  border-top: 1px solid var(${p}-border);
}
.service-row:first-child, .log-item:first-child { border-top: 0; padding-top: 4px; }
.service-row:last-child, .log-item:last-child { padding-bottom: 2px; }
.service-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
}
.service-meta { display: inline-flex; align-items: center; gap: 12px; flex-shrink: 0; }
.uptime-pct { font-size: 13px; font-variant-numeric: tabular-nums; color: var(${p}-muted); }
.badge {
  display: inline-block;
  padding: 3px 10px;
  font-size: 12px;
  font-weight: 600;
  border-radius: 999px;
}
.badge-ok { color: var(${p}-ok); background: var(${p}-ok-bg); }
.badge-neutral {
  color: var(${p}-muted);
  background: var(${p}-surface-alt);
  border: 1px solid var(${p}-border);
}
.uptime-bars {
  display: grid;
  grid-template-columns: repeat(24, minmax(0, 1fr));
  gap: 4px;
  margin-top: 8px;
}
.uptime-seg { height: 28px; border-radius: 3px; background: var(${p}-ok); opacity: 0.85; }
.uptime-axis {
  display: flex;
  justify-content: space-between;
  margin-top: 8px;
  font-size: 12px;
  color: var(${p}-muted);
}
.log-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.log-time { display: inline-block; margin-top: 6px; font-size: 12px; color: var(${p}-muted); }
.doc-card { display: block; color: inherit; }
.doc-card:hover { border-color: var(${p}-accent); text-decoration: none; }
.doc-card p { margin: 0; font-size: 14px; color: var(${p}-muted); }
.doc-section p { margin: 0 0 12px; font-size: 14px; color: var(${p}-muted); }
.bullet-list { margin: 10px 0 0; padding-left: 20px; font-size: 14px; color: var(${p}-muted); }
.bullet-list li { margin: 6px 0; }
.table-wrap { overflow-x: auto; }
.meta-table { width: 100%; border-collapse: collapse; font-size: 14px; }
.meta-table th, .meta-table td {
  padding: 10px 12px;
  text-align: left;
  border-bottom: 1px solid var(${p}-border);
}
.meta-table th { font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(${p}-muted); }
.metrics {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 14px;
  margin-top: 22px;
}
.metric {
  padding: 16px;
  background: var(${p}-surface);
  border: 1px solid var(${p}-border);
  border-radius: var(${p}-radius);
}
.metric-value { display: block; font-size: 20px; font-weight: 700; }
.metric-label { display: block; margin-top: 2px; font-size: 13px; color: var(${p}-muted); }
.principles { margin: 8px 0 0; padding-left: 20px; font-size: 14px; color: var(${p}-muted); }
.principles li { margin: 8px 0; }
.principles strong { color: var(${p}-text); }
.cta-box {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
}
.error-card { text-align: center; padding: 36px 28px; }
.error-code {
  margin: 0 0 6px;
  font-size: 40px;
  font-weight: 700;
  color: var(${p}-accent);
  line-height: 1.1;
}
.site-footer {
  border-top: 1px solid var(${p}-border);
  padding: 20px 0 28px;
  font-size: 13px;
  color: var(${p}-muted);
}
.footer-inner {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  gap: 8px 16px;
}
.footer-inner p { margin: 0; }
@media (max-width: 720px) {
  .grid-2, .grid-3, .metrics { grid-template-columns: 1fr; }
  .topbar-inner { flex-direction: column; align-items: flex-start; padding: 12px 0; }
  .service-row { flex-direction: column; align-items: flex-start; }
}
EOF
    [[ -s "${CAMOUFLAGE_DIR}/assets/site.css" ]] \
        || die "写入伪装站样式失败：${CAMOUFLAGE_DIR}/assets/site.css"

    cat >"${CAMOUFLAGE_DIR}/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <title>${brand}</title>
  <defs>
    <linearGradient id="g-${build_id}" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="${accent}"/>
      <stop offset="100%" stop-color="${accent_hover}"/>
    </linearGradient>
  </defs>
  <rect width="64" height="64" rx="${svg_rx}" fill="url(#g-${build_id})"/>
  <text x="32" y="42" text-anchor="middle" fill="#ffffff" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif" font-size="30" font-weight="600">${brand_initial}</text>
</svg>
EOF
    [[ -s "${CAMOUFLAGE_DIR}/favicon.svg" ]] \
        || die "写入伪装站图标失败：${CAMOUFLAGE_DIR}/favicon.svg"

    printf 'User-agent: *\nDisallow: /\n' >"${CAMOUFLAGE_DIR}/robots.txt" \
        || die "写入伪装站 robots.txt 失败：${CAMOUFLAGE_DIR}/robots.txt"

    cat >"${CAMOUFLAGE_DIR}/404.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="generator" content="${brand} Web ${build_id}">
<title>Page Not Found — ${brand}</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/assets/site.css">
</head>
<body class="page-error">
<main class="error-wrap">
  <section class="card error-card">
    <p class="error-code">404</p>
    <h1>Page not found</h1>
    <p class="subtitle">The requested resource on <code>${domain}</code> could not be found.</p>
    <div class="action-row" style="justify-content:center">
      <a class="btn-primary btn-inline" href="/">Return home</a>
    </div>
  </section>
  <footer class="auth-footer">
    <p>&copy; ${year} ${brand} · build ${build_id}</p>
  </footer>
</main>
</body>
</html>
EOF
    [[ -s "${CAMOUFLAGE_DIR}/404.html" ]] \
        || die "写入伪装站 404 页面失败：${CAMOUFLAGE_DIR}/404.html"

    managed=(
        "index.html"
        "404.html"
        "robots.txt"
        "favicon.svg"
        "assets/site.css"
    )

    if [[ "${archetype}" == "login" ]]; then
        cat >"${CAMOUFLAGE_DIR}/assets/auth.js" <<'EOF'
(function () {
  var form = document.getElementById("auth-form");
  var statusBox = document.getElementById("auth-status");
  var submitBtn = document.getElementById("auth-submit");
  var emailInput = document.getElementById("email");
  var passwordInput = document.getElementById("password");
  if (!form || !statusBox || !submitBtn || !emailInput || !passwordInput) {
    return;
  }

  function showError(message) {
    statusBox.textContent = message;
    statusBox.hidden = false;
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var email = emailInput.value.trim();
    var password = passwordInput.value;
    if (!email || !password) {
      showError("Please enter your work email and password.");
      return;
    }

    statusBox.hidden = true;
    submitBtn.disabled = true;
    submitBtn.textContent = "Signing in...";

    var delayMs = 180 + Math.floor(Math.random() * 141);
    var wait = new Promise(function (resolve) {
      window.setTimeout(resolve, delayMs);
    });
    var request = fetch("/api/auth/login", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json"
      },
      credentials: "same-origin",
      body: JSON.stringify({ email: email, password: password })
    })
      .then(function (res) {
        return res.json().catch(function () {
          return null;
        });
      })
      .catch(function () {
        return null;
      });

    Promise.all([request, wait]).then(function (results) {
      var payload = results[0];
      var message = (payload && (payload.error || payload.message))
        || "Invalid email or password.";
      showError(message);
      passwordInput.value = "";
      submitBtn.disabled = false;
      submitBtn.textContent = "Sign in";
      passwordInput.focus();
    });
  });
})();
EOF
        [[ -s "${CAMOUFLAGE_DIR}/assets/auth.js" ]] \
            || die "写入伪装站登录脚本失败：${CAMOUFLAGE_DIR}/assets/auth.js"
        managed+=("assets/auth.js" "login/index.html")
    fi

    # index.html 最后落盘：若前置写入失败，不会提前留下 index.html 导致续装跳过。
    CAMO_BRAND="${brand}" \
    CAMO_TITLE="${title}" \
    CAMO_SUBTITLE="${subtitle}" \
    CAMO_DOMAIN="${domain}" \
    CAMO_CONTACT_EMAIL="${contact_email}" \
    CAMO_YEAR="${year}" \
    CAMO_TAGLINE="${tagline}" \
    CAMO_BUILD_ID="${build_id}" \
    CAMO_FOOTER_NOTE="${footer_note}" \
    awk '
        function sub_all(str, key, val,    pos, out, klen) {
            klen = length(key)
            out = ""
            while ((pos = index(str, key)) > 0) {
                out = out substr(str, 1, pos - 1) val
                str = substr(str, pos + klen)
            }
            return out str
        }
        {
            line = $0
            line = sub_all(line, "__BRAND__", ENVIRON["CAMO_BRAND"])
            line = sub_all(line, "__TITLE__", ENVIRON["CAMO_TITLE"])
            line = sub_all(line, "__SUBTITLE__", ENVIRON["CAMO_SUBTITLE"])
            line = sub_all(line, "__DOMAIN__", ENVIRON["CAMO_DOMAIN"])
            line = sub_all(line, "__CONTACT_EMAIL__", ENVIRON["CAMO_CONTACT_EMAIL"])
            line = sub_all(line, "__YEAR__", ENVIRON["CAMO_YEAR"])
            line = sub_all(line, "__TAGLINE__", ENVIRON["CAMO_TAGLINE"])
            line = sub_all(line, "__BUILD_ID__", ENVIRON["CAMO_BUILD_ID"])
            line = sub_all(line, "__FOOTER_NOTE__", ENVIRON["CAMO_FOOTER_NOTE"])
            print line
        }
    ' "${template}" >"${CAMOUFLAGE_DIR}/index.html" \
        || die "部署伪装站页面失败：${CAMOUFLAGE_DIR}/index.html"

    if [[ "${archetype}" == "login" ]]; then
        install -m 0644 "${CAMOUFLAGE_DIR}/index.html" "${CAMOUFLAGE_DIR}/login/index.html" \
            || die "部署伪装站登录页失败：${CAMOUFLAGE_DIR}/login/index.html"
    fi

    for file in "${managed[@]}"; do
        chmod 0644 "${CAMOUFLAGE_DIR}/${file}" \
            || die "设置伪装站文件权限失败：${CAMOUFLAGE_DIR}/${file}"
    done

    manifest=$(camouflage_managed_manifest_file)
    install -d -m 0700 "${STATE_DIR}" || die "创建状态目录失败：${STATE_DIR}"
    printf '%s\n' "${managed[@]}" >"${manifest}" \
        || die "写入伪装站受管清单失败：${manifest}"
    chmod 0600 "${manifest}" || die "设置伪装站受管清单权限失败：${manifest}"
}

camouflage_remove_managed_files() {
    [[ -n "${CAMOUFLAGE_DIR:-}" ]] || return 0
    local manifest rel
    manifest=$(camouflage_managed_manifest_file)
    if [[ -f "${manifest}" ]]; then
        while IFS= read -r rel || [[ -n "${rel}" ]]; do
            case "${rel}" in
            "" | "." | /* | *..* | */) continue ;;
            esac
            rm -f -- "${CAMOUFLAGE_DIR}/${rel}" 2>/dev/null || true
        done <"${manifest}"
        rm -f -- "${manifest}" 2>/dev/null || true
    else
        # 旧版安装或 uninstall_incomplete：无清单时按固定受管集合回收。
        for rel in \
            index.html \
            404.html \
            robots.txt \
            favicon.svg \
            assets/site.css \
            assets/auth.js \
            login/index.html; do
            rm -f -- "${CAMOUFLAGE_DIR}/${rel}" 2>/dev/null || true
        done
    fi
    rmdir "${CAMOUFLAGE_DIR}/assets" "${CAMOUFLAGE_DIR}/login" "${CAMOUFLAGE_DIR}" 2>/dev/null || true
}

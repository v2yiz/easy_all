/**
 * Cloudflare Worker: EASY_ALL Shadowrocket configuration
 *
 * 配置地址：
 * https://你的Worker域名/EASY_ALL.conf
 */

const UPSTREAM_URL =
  "https://johnshall.github.io/Shadowrocket-ADBlock-Rules-Forever/lazy.conf";

const DOWNLOAD_PATH = "/EASY_ALL.conf";
const DOWNLOAD_NAME = "EASY_ALL.conf";

const TEST_URL = "https://cp.cloudflare.com/generate_204";
const TEST_INTERVAL_SECONDS = 300;
const TEST_TOLERANCE_MS = 30;
const TEST_TIMEOUT_SECONDS = 5;

const FETCH_TIMEOUT_MS = 15_000;

// 上游暂时无法访问时，最近成功版本最多保留三天。
const STALE_CACHE_SECONDS = 3 * 24 * 60 * 60;

// 生成逻辑或缓存策略变化时递增，避免继续命中旧部署留下的缓存。
const CACHE_VERSION = "v3";

// 本地 IPv6 地址不经过代理和 TUN。
const LOCAL_IPV6_RANGES = [
  "::1/128",
  "fc00::/7",
  "fe80::/10",
  "ff00::/8",
];

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, ctx);
  },
};

async function handleRequest(request, ctx) {
  const url = new URL(request.url);
  const canonicalUrl = `${url.origin}${DOWNLOAD_PATH}`;

  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method Not Allowed\n", {
      status: 405,
      headers: {
        Allow: "GET, HEAD",
        "Content-Type": "text/plain; charset=utf-8",
      },
    });
  }

  if (url.pathname === "/") {
    return new Response(
      `请使用完整配置地址：${canonicalUrl}\n`,
      {
        status: 400,
        headers: {
          "Content-Type": "text/plain; charset=utf-8",
        },
      },
    );
  }

  if (url.pathname !== DOWNLOAD_PATH) {
    return new Response("Not Found\n", {
      status: 404,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
      },
    });
  }

  const cache = caches.default;

  const staleCacheKey = makeCacheKey(
    canonicalUrl,
    "stale",
  );

  try {
    const upstreamText = await fetchUpstream();

    const transformed = transformConfig(
      upstreamText,
      canonicalUrl,
    );

    const staleEntry = cacheEntry(
      transformed,
      STALE_CACHE_SECONDS,
    );

    ctx.waitUntil(
      cache.put(staleCacheKey, staleEntry),
    );

    return serveConfig(
      transformed,
      request.method,
      canonicalUrl,
      "LIVE",
    );
  } catch (error) {
    const stale = await cache.match(staleCacheKey);

    if (stale) {
      return serveConfig(
        await stale.text(),
        request.method,
        canonicalUrl,
        "STALE",
      );
    }

    const message =
      error instanceof Error
        ? error.message
        : String(error);

    return new Response(
      `上游配置拉取或处理失败：${message}\n`,
      {
        status: 502,
        headers: {
          "Content-Type":
            "text/plain; charset=utf-8",
          "Cache-Control": "no-store",
          "Access-Control-Allow-Origin": "*",
          "X-Content-Type-Options": "nosniff",
        },
      },
    );
  }
}

async function fetchUpstream() {
  const controller = new AbortController();

  const timer = setTimeout(
    () => controller.abort(),
    FETCH_TIMEOUT_MS,
  );

  try {
    const response = await fetch(UPSTREAM_URL, {
      method: "GET",
      redirect: "follow",
      signal: controller.signal,

      headers: {
        Accept: "text/plain,*/*;q=0.8",
        "User-Agent": "EASY_ALL-Worker/1.0",
      },
    });

    if (!response.ok) {
      throw new Error(
        `HTTP ${response.status} ${response.statusText}`,
      );
    }

    const text = await response.text();

    validateUpstream(text);

    return text;
  } catch (error) {
    if (
      error instanceof Error &&
      error.name === "AbortError"
    ) {
      throw new Error(
        `请求上游超过 ${
          FETCH_TIMEOUT_MS / 1000
        } 秒`,
      );
    }

    throw error;
  } finally {
    clearTimeout(timer);
  }
}

function validateUpstream(text) {
  if (text.length < 1_000) {
    throw new Error(
      "上游返回内容过短，拒绝生成配置",
    );
  }

  const requiredSections = [
    "[General]",
    "[Proxy Group]",
    "[Rule]",
  ];

  for (const section of requiredSections) {
    if (!text.includes(section)) {
      throw new Error(
        `上游缺少必要区段 ${section}`,
      );
    }
  }
}

function transformConfig(
  source,
  canonicalUrl,
) {
  let lines = source
    .replace(/^\uFEFF/, "")
    .replace(/\r\n?/g, "\n")
    .split("\n");

  // 写入当前 Worker 配置更新地址。
  lines = upsertGeneralValue(
    lines,
    "update-url",
    canonicalUrl,
  );

  // 明确启用 IPv6。
  lines = upsertGeneralValue(
    lines,
    "ipv6",
    "true",
  );

  // 本地 IPv6 地址跳过代理。
  lines = mergeGeneralCsv(
    lines,
    "skip-proxy",
    LOCAL_IPV6_RANGES,
  );

  // 本地 IPv6 地址绕过 TUN。
  lines = mergeGeneralCsv(
    lines,
    "tun-excluded-routes",
    LOCAL_IPV6_RANGES,
  );

  // 注入 AUTO 策略组。
  lines = injectAutoGroup(lines);

  // 将上游所有生效的 PROXY 规则统一交给 AUTO 自动测速选择。
  lines = rewriteProxyRulesToAuto(lines);

  return (
    lines
      .join("\n")
      .replace(/\n+$/, "") + "\n"
  );
}

function upsertGeneralValue(
  lines,
  key,
  value,
) {
  const { start, end } = findSection(
    lines,
    "General",
  );

  const keyPattern = new RegExp(
    `^\\s*${escapeRegExp(key)}\\s*=`,
    "i",
  );

  let found = false;
  const output = [];

  for (
    let i = 0;
    i < lines.length;
    i += 1
  ) {
    const line = lines[i];

    if (
      i > start &&
      i < end &&
      keyPattern.test(line) &&
      !isComment(line)
    ) {
      if (!found) {
        output.push(`${key} = ${value}`);
        found = true;
      }

      // 删除重复的同名设置。
      continue;
    }

    output.push(line);
  }

  if (!found) {
    output.splice(
      start + 1,
      0,
      `${key} = ${value}`,
    );
  }

  return output;
}

function mergeGeneralCsv(
  lines,
  key,
  additions,
) {
  const { start, end } = findSection(
    lines,
    "General",
  );

  const keyPattern = new RegExp(
    `^(\\s*${escapeRegExp(
      key,
    )}\\s*=\\s*)(.*)$`,
    "i",
  );

  for (
    let i = start + 1;
    i < end;
    i += 1
  ) {
    if (isComment(lines[i])) {
      continue;
    }

    const match = lines[i].match(
      keyPattern,
    );

    if (!match) {
      continue;
    }

    const values = match[2]
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);

    const seen = new Set(
      values.map((item) =>
        item.toLowerCase(),
      ),
    );

    for (const addition of additions) {
      const normalized =
        addition.toLowerCase();

      if (!seen.has(normalized)) {
        values.push(addition);
        seen.add(normalized);
      }
    }

    lines[i] =
      `${match[1]}${values.join(",")}`;

    return lines;
  }

  // 如果上游没有对应设置，则自动创建。
  lines.splice(
    start + 1,
    0,
    `${key} = ${additions.join(",")}`,
  );

  return lines;
}

function injectAutoGroup(lines) {
  let { start, end } = findSection(
    lines,
    "Proxy Group",
  );

  const generatedComment =
    "# EASY_ALL：所有订阅节点自动测速切换";

  const autoPattern =
    /^\s*AUTO\s*=/i;

  // 先移除以前生成过的 AUTO，避免重复。
  lines = lines.filter(
    (line, index) => {
      if (
        index <= start ||
        index >= end
      ) {
        return true;
      }

      if (
        line.trim() === generatedComment
      ) {
        return false;
      }

      return (
        isComment(line) ||
        !autoPattern.test(line)
      );
    },
  );

  ({ start, end } = findSection(
    lines,
    "Proxy Group",
  ));

  let insertAt = end;

  // 插入到第一个真实策略组之前。
  for (
    let i = start + 1;
    i < end;
    i += 1
  ) {
    if (
      !isComment(lines[i]) &&
      /^\s*[^=]+\s*=/.test(lines[i])
    ) {
      insertAt = i;
      break;
    }
  }

  const autoLine = [
    "AUTO = url-test",
    `url=${TEST_URL}`,
    `interval=${TEST_INTERVAL_SECONDS}`,
    `tolerance=${TEST_TOLERANCE_MS}`,
    `timeout=${TEST_TIMEOUT_SECONDS}`,
    "select=0",
  ].join(",");

  lines.splice(
    insertAt,
    0,
    generatedComment,
    autoLine,
  );

  return lines;
}

function rewriteProxyRulesToAuto(lines) {
  const { start, end } = findSection(
    lines,
    "Rule",
  );

  return lines.map((line, index) => {
    if (
      index <= start ||
      index >= end ||
      isComment(line)
    ) {
      return line;
    }

    // Shadowrocket 规则的策略位于末尾；只替换明确以 PROXY 结尾的生效规则。
    return line.replace(
      /,(\s*)PROXY(\s*)$/i,
      ",$1AUTO$2",
    );
  });
}

function findSection(
  lines,
  name,
) {
  const header =
    `[${name}]`.toLowerCase();

  const start = lines.findIndex(
    (line) =>
      line.trim().toLowerCase() ===
      header,
  );

  if (start < 0) {
    throw new Error(
      `配置缺少 [${name}] 区段`,
    );
  }

  let end = lines.length;

  for (
    let i = start + 1;
    i < lines.length;
    i += 1
  ) {
    if (
      /^\s*\[[^\]]+\]\s*$/.test(
        lines[i],
      )
    ) {
      end = i;
      break;
    }
  }

  return { start, end };
}

function isComment(line) {
  return /^\s*[#;]/.test(line);
}

function escapeRegExp(value) {
  return value.replace(
    /[.*+?^${}()|[\]\\]/g,
    "\\$&",
  );
}

function makeCacheKey(
  canonicalUrl,
  kind,
) {
  const url = new URL(canonicalUrl);

  url.searchParams.set(
    "__easy_all_cache",
    kind,
  );

  url.searchParams.set(
    "__easy_all_version",
    CACHE_VERSION,
  );

  return new Request(
    url.toString(),
    {
      method: "GET",
    },
  );
}

function cacheEntry(body, ttl) {
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type":
        "text/plain; charset=utf-8",

      "Cache-Control":
        `public, max-age=${ttl}, s-maxage=${ttl}`,
    },
  });
}

function serveConfig(
  body,
  method,
  canonicalUrl,
  cacheStatus,
) {
  const headers = {
    "Content-Type":
      "text/plain; charset=utf-8",

    "Content-Disposition":
      `attachment; filename=${DOWNLOAD_NAME}; ` +
      `filename*=UTF-8''${DOWNLOAD_NAME}`,

    // 每次更新都向 Worker 获取实时生成结果；仅 Worker 内部保留失败回退。
    "Cache-Control": "no-cache, no-store, must-revalidate",

    "Access-Control-Allow-Origin": "*",

    "X-Content-Type-Options":
      "nosniff",

    "X-EASY-ALL-Source":
      UPSTREAM_URL,

    "X-EASY-ALL-URL":
      canonicalUrl,

    "X-EASY-ALL-Cache":
      cacheStatus,
  };

  return new Response(
    method === "HEAD" ? null : body,
    {
      status: 200,
      headers,
    },
  );
}

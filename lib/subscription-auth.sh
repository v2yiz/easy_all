#!/usr/bin/env bash

# Shared validation and rendering for non-quota subscription credentials.

generate_secret() {
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
}

normalize_allowed_tokens() {
    local raw=$1
    jq -cer '
        def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
        if type != "object" then
            error("ALLOWED_TOKENS 必须是 JSON object")
        else
            to_entries as $entries
            | if ($entries | length) == 0 then
                error("ALLOWED_TOKENS 不能为空")
            else
                if any($entries[]; (.value | type) != "string") then
                    error("ALLOWED_TOKENS token 值必须是字符串")
                else
                    [ $entries[] | {key: (.key | trim), value: (.value | trim)} ] as $clean
                    | if any($clean[]; .key == "" or .value == "") then
                    error("ALLOWED_TOKENS 不允许空用户名或空 token")
                    elif any($clean[]; (.key | test("^[A-Za-z0-9._-]{1,64}$") | not)) then
                    error("ALLOWED_TOKENS 用户名只能包含字母、数字、点、下划线、短横线，长度 1-64")
                    elif any($clean[]; (.value | test("^[A-Za-z0-9._~-]{8,128}$") | not)) then
                    error("ALLOWED_TOKENS token 只能包含 URL 安全字符 A-Z a-z 0-9 . _ ~ -，长度 8-128")
                    elif (($clean | map(.key) | unique | length) != ($clean | length)) then
                    error("ALLOWED_TOKENS 清洗后存在重复用户名")
                    elif (($clean | map(.value) | unique | length) != ($clean | length)) then
                    error("ALLOWED_TOKENS 不允许重复 token")
                    else
                    $clean | from_entries
                    end
                end
            end
        end
    ' <<<"${raw}"
}

ensure_allowed_tokens() {
    local raw prompt_default normalized
    if [[ -n "${ALLOWED_TOKENS:-}" ]]; then
        raw=${ALLOWED_TOKENS}
    elif [[ -t 0 ]]; then
        prompt_default=$(jq -cn --arg token "$(generate_secret)" '{owner: $token}')
        raw=$(prompt_value "订阅用户 Token 字典 JSON（用户名=>token）" "${prompt_default}" \
            "Subscription user Token map JSON (username => Token)")
    else
        die "非交互模式必须设置 ALLOWED_TOKENS，例如 ALLOWED_TOKENS='{\"owner\":\"$(generate_secret)\"}'"
    fi

    normalized=$(normalize_allowed_tokens "${raw}") \
        || die "ALLOWED_TOKENS 无效；请使用 JSON 对象，例如 {\"owner\":\"$(generate_secret)\"}"
    ALLOWED_TOKENS=${normalized}
}

write_subscription_token_map() {
    if quota_enabled; then
        jq -r 'to_entries[] | "    \"" + .value.token + "\" \"" + .key + "\";"' \
            <<<"$(quota_active_accounts_json)"
        return 0
    fi
    jq -r '.[] | "    \"" + . + "\" 1;"' <<<"${ALLOWED_TOKENS}"
}

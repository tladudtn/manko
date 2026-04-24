#!/bin/bash
# Token calculation utilities for man page chunking

# Model path
MODEL_PATH="${MODEL_PATH:-$HOME/Projects/llama/models/google_gemma-3-12b-it-Q4_K_L.gguf}"

# content_hash 캐시 (동일 청크 + 동일 모델에 대한 llama-tokenize 재호출 회피)
TOKEN_CACHE_DIR="${TOKEN_CACHE_DIR:-$HOME/.cache/manko/token_cache}"

# Count exact tokens using llama-tokenize (캐시 적용)
count_tokens_exact() {
    local file="$1"
    local model="${2:-$MODEL_PATH}"

    if [ ! -f "$file" ]; then
        echo "Error: File not found - $file" >&2
        return 1
    fi

    if [ ! -f "$model" ]; then
        echo "Error: Model not found - $model" >&2
        return 1
    fi

    # 캐시 키: sha1(파일내용 + 모델 basename). 모델 바꾸면 토큰화 결과 달라지므로 키에 포함.
    mkdir -p "$TOKEN_CACHE_DIR"
    local model_tag hash cache_file
    model_tag=$(basename "$model")
    hash=$({ cat "$file"; printf '\n__model__=%s' "$model_tag"; } | sha1sum | awk '{print $1}')
    cache_file="$TOKEN_CACHE_DIR/$hash"

    if [ -f "$cache_file" ]; then
        cat "$cache_file"
        return 0
    fi

    local tok
    tok=$(llama-tokenize -m "$model" -f "$file" \
            --show-count --log-disable 2>&1 |
            grep "Total number of tokens:" |
            awk '{print $NF}')

    if [ -n "$tok" ]; then
        echo "$tok" > "$cache_file"
        echo "$tok"
    fi
}

# 3단 캐스케이드 토큰 추정 (CLAUDE.md "토큰 측정 캐스케이드")
#   1단: chars/3 (무료, "확실히 초과" 빠른 컷)
#   2단: lines×21 (무료, 누적 중 추정)
#   3단: llama-tokenize + 캐시 (청크 확정 시 1회 검증)
#
# 사용:
#   count_tokens_cascade <file> <max_tok> [model]
#   - max_tok 초과 "확실" (1단/2단 모두 초과) → 추정치 반환 (3단 skip)
#   - 경계에 걸침 → 3단 호출하여 정확치 반환
count_tokens_cascade() {
    local file="$1"
    local max_tok="$2"
    local model="${3:-$MODEL_PATH}"

    local chars lines est1 est2
    chars=$(wc -c < "$file")
    lines=$(wc -l < "$file")
    est1=$((chars / 3))
    est2=$((lines * 21))

    # 두 추정치 모두 max 의 1.3배 이상이면 정확 측정 불필요 (확실 초과)
    local safety=$((max_tok * 130 / 100))
    if [ "$est1" -gt "$safety" ] && [ "$est2" -gt "$safety" ]; then
        # 보수적으로 큰 쪽 반환
        [ "$est1" -gt "$est2" ] && echo "$est1" || echo "$est2"
        return 0
    fi

    # 두 추정치 모두 max 의 0.7배 미만이면 정확 측정 불필요 (확실 여유)
    local comfort=$((max_tok * 70 / 100))
    if [ "$est1" -lt "$comfort" ] && [ "$est2" -lt "$comfort" ]; then
        [ "$est1" -gt "$est2" ] && echo "$est1" || echo "$est2"
        return 0
    fi

    # 경계 영역 → 정확 측정 (캐시 적용)
    count_tokens_exact "$file" "$model"
}

# Count tokens from stdin
count_tokens_stdin() {
    local model="${1:-$MODEL_PATH}"

    if [ ! -f "$model" ]; then
        echo "Error: Model not found - $model" >&2
        return 1
    fi

    llama-tokenize -m "$model" --stdin \
        --show-count --log-disable 2>&1 |
        grep "Total number of tokens:" |
        awk '{print $NF}'
}

# Estimate tokens from line count (fast mode)
estimate_tokens() {
    local lines="$1"
    local tokens_per_line="${2:-21}"  # Conservative estimate
    echo $((lines * tokens_per_line))
}

# Validate chunk is within token limit
validate_chunk() {
    local file="$1"
    local max_tokens="${2:-8000}"
    local model="${3:-$MODEL_PATH}"

    local actual=$(count_tokens_exact "$file" "$model")

    if [ -z "$actual" ]; then
        echo "Error: Could not count tokens" >&2
        return 1
    fi

    if [ "$actual" -le "$max_tokens" ]; then
        echo "✓ $actual tokens (limit: $max_tokens)"
        return 0
    else
        echo "✗ $actual tokens (exceeds $max_tokens)"
        return 1
    fi
}

# If script is executed directly, provide CLI interface
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    case "${1:-}" in
        count)
            shift
            count_tokens_exact "$@"
            ;;
        estimate)
            shift
            estimate_tokens "$@"
            ;;
        validate)
            shift
            validate_chunk "$@"
            ;;
        stdin)
            shift
            count_tokens_stdin "$@"
            ;;
        cascade)
            shift
            count_tokens_cascade "$@"
            ;;
        *)
            echo "Usage: $0 {count|estimate|validate|stdin|cascade} [args...]"
            echo ""
            echo "Commands:"
            echo "  count <file> [model]               Count exact tokens (cached)"
            echo "  estimate <lines> [tpl]             Estimate tokens from line count"
            echo "  validate <file> [max] [model]      Validate chunk size"
            echo "  stdin [model]                      Count tokens from stdin"
            echo "  cascade <file> <max> [model]       3-tier cascade (chars/3 → lines×21 → exact)"
            echo ""
            echo "Environment:"
            echo "  MODEL_PATH=${MODEL_PATH}"
            echo "  TOKEN_CACHE_DIR=${TOKEN_CACHE_DIR}"
            exit 1
            ;;
    esac
fi

#!/bin/bash
# PoC: 청킹(5단계 재귀 분할 + 탐욕 병합) → 토크나이저 검증(캐시) → gemma-4-E4B 번역
# 사용법: ./run_translate.sh <command>

set -uo pipefail

CMD="${1:-cat}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
MAX_INPUT_TOKENS=3500

# 모델 선택 (env MODEL_KEY 로 지정, 기본 e4b)
#   e4b  : gemma-4-E4B Q8_0 (VRAM 풀로딩, 빠름)
#   26b  : gemma-4-26B-A4B MoE Q4_K_M (12GB VRAM 에 안 맞아 --n-cpu-moe 99 로 MoE CPU 오프로드)
MODEL_KEY="${MODEL_KEY:-e4b}"
LLAMA_EXTRA_ARGS=()
case "$MODEL_KEY" in
    e4b)
        MODEL="$ROOT/models/gemma-4-E4B-it-Q8_0.gguf"
        ;;
    26b)
        MODEL="$ROOT/models/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"
        LLAMA_EXTRA_ARGS=(--n-cpu-moe "${N_CPU_MOE:-99}")
        ;;
    supergemma)
        MODEL="$ROOT/models/supergemma4-26b-uncensored-fast-v2-Q4_K_M.gguf"
        LLAMA_EXTRA_ARGS=(--n-cpu-moe "${N_CPU_MOE:-99}")
        ;;
    *)
        echo "Unknown MODEL_KEY=$MODEL_KEY (expected: e4b | 26b | supergemma)" >&2
        exit 1
        ;;
esac

# 작업 디렉토리 (env WORK 로 override 가능)
WORK="${WORK:-$ROOT/tmp/$CMD}"
SOURCE="$WORK/source.txt"
CHUNKS_DIR="$WORK/chunks"        # 원문 청크
BODIES_DIR="$WORK/bodies"        # 헤더를 마커로 치환한 본문 (번역 입력)
HEADERS_DIR="$WORK/headers"      # 마커 인덱스 → 원본 헤더 매핑
TRANS_DIR="$WORK/trans"          # 번역 결과 (마커 복원 후, 기존 단계 5 입력)
POST_DIR="$WORK/post"            # 후처리 (들여쓰기 복원)
RESULT="$WORK/${CMD}_ko.txt"
OUT_FILE="${OUT_FILE:-}"         # 지정 시 최종 결과를 해당 경로에도 복사

[ -f "$MODEL" ] || { echo "Model not found: $MODEL" >&2; exit 1; }
echo "[model] $MODEL_KEY: $(basename "$MODEL")" >&2
[ ${#LLAMA_EXTRA_ARGS[@]} -gt 0 ] && echo "[model] extra args: ${LLAMA_EXTRA_ARGS[*]}" >&2
source "$ROOT/token_utils.sh"
source "$ROOT/recursive_chunk.sh"
export MODEL_PATH="$MODEL"

rm -rf "$WORK"
mkdir -p "$CHUNKS_DIR" "$BODIES_DIR" "$HEADERS_DIR" "$TRANS_DIR" "$POST_DIR"

# 1) 원문 추출
echo "[1/5] Extracting man $CMD..." >&2
man "$CMD" 2>/dev/null | col -bx > "$SOURCE"
[ -s "$SOURCE" ] || { echo "Failed: 'man $CMD' empty" >&2; exit 1; }
SRC_LINES=$(wc -l < "$SOURCE")
echo "   -> $SRC_LINES lines" >&2

# 2) 청킹: 5단계 재귀 분할 + 탐욕 병합 (recursive_chunk.sh)
echo "[2/5] Chunking (recursive split + greedy merge, max=$MAX_INPUT_TOKENS tok)..." >&2
chunk_text "$SOURCE" "$CHUNKS_DIR" "$CMD" "$MAX_INPUT_TOKENS"
N_CHUNKS=$(ls "$CHUNKS_DIR" | wc -l)
echo "   -> $N_CHUNKS chunks" >&2

# 3) 토크나이저 검증 (llama-tokenize, content_hash 캐시 적용)
echo "[3/5] Tokenizing each chunk (limit: $MAX_INPUT_TOKENS)..." >&2
TOTAL_TOK=0
EXCEEDED=0
for f in "$CHUNKS_DIR"/*.txt; do
    tok=$(count_tokens_exact "$f" 2>/dev/null)
    [ -z "$tok" ] && tok=0
    TOTAL_TOK=$((TOTAL_TOK + tok))
    bn=$(basename "$f")
    head1=$(head -1 "$f" | cut -c1-40)
    if [ "$tok" -gt "$MAX_INPUT_TOKENS" ]; then
        printf "  ⚠ %-22s %5d tok (>%d)  | %s\n" "$bn" "$tok" "$MAX_INPUT_TOKENS" "$head1" >&2
        EXCEEDED=$((EXCEEDED + 1))
    else
        printf "  ✓ %-22s %5d tok          | %s\n" "$bn" "$tok" "$head1" >&2
    fi
done
echo "   -> total $TOTAL_TOK tokens, $EXCEEDED chunks exceed limit" >&2

# 청킹 무결성 점검: 청크 합계 줄 수가 원본과 일치해야 함
CHUNK_TOTAL_LINES=$(cat "$CHUNKS_DIR"/*.txt | wc -l)
if [ "$CHUNK_TOTAL_LINES" -ne "$SRC_LINES" ]; then
    echo "WARN: chunk total lines ($CHUNK_TOTAL_LINES) != source ($SRC_LINES) — 청킹 단계에서 줄 손실/중복" >&2
fi

if [ "$EXCEEDED" -gt 0 ]; then
    echo "WARN: $EXCEEDED chunks exceed limit despite recursive split (LINE fallback 도 한도 초과)." >&2
fi

# 3.5) 헤더 분리 + 앵커 주입
# (a) 헤더 분리: Title-Case SUBSECTION 만 [[[MANKO_HDR_NNN]]] 마커로 치환 (번역 방지).
#     ALL-CAPS 헤더 (NAME, GLOBAL OPTIONS 등)는 본문에 유지 — 번역 앵커 역할.
# (b) 앵커 주입: 청크가 ALL-CAPS 헤더로 시작하지 않으면 (find_002: OPTIONS 중간 분할),
#     원문에서 가장 가까운 선행 ALL-CAPS 헤더를 body 첫 줄에 synthetic prefix 로 추가.
#     번역 후 prefix 줄만 strip → step 5 의 src 1:1 매칭과 정합성 유지.
echo "[3.5/5] Splitting headers + injecting anchors..." >&2
TOTAL_HDR=0
TOTAL_ANCHOR=0
CUM_LINE=0
ANCHOR_MAP="$WORK/anchor_prefix.txt"   # <bn>\t<prefix_line_count>
: > "$ANCHOR_MAP"
for f in "$CHUNKS_DIR"/*.txt; do
    bn=$(basename "$f" .txt)
    body="$BODIES_DIR/$bn.txt"
    hmap="$HEADERS_DIR/$bn.txt"
    : > "$hmap"

    n=$(wc -l < "$f")
    start=$((CUM_LINE + 1))
    CUM_LINE=$((CUM_LINE + n))

    # 청크 첫 5 non-blank 줄에 ALL-CAPS 헤더 있나? (col-0 또는 col-3)
    has_anchor=$(awk '
        /^[[:space:]]*$/ { next }
        { count++; if (count > 5) exit }
        /^[A-Z][A-Z0-9 ()-]+$/ && length($0) < 50 { print 1; exit }
        /^   [A-Z][A-Z0-9 ()-]+$/ && length($0) < 50 { print 1; exit }
    ' "$f")

    prefix_n=0
    if [ -z "$has_anchor" ]; then
        # 원문 start 이전의 가장 최근 ALL-CAPS 헤더
        anchor=$(awk -v pos="$start" '
            NR >= pos { exit }
            (/^[A-Z][A-Z0-9 ()-]+$/ || /^   [A-Z][A-Z0-9 ()-]+$/) && length($0) < 50 { last = $0 }
            END { print last }
        ' "$SOURCE")
        if [ -n "$anchor" ]; then
            { printf '%s\n\n' "$anchor"; cat "$f"; } > "$body.tmp"
            prefix_n=2
            TOTAL_ANCHOR=$((TOTAL_ANCHOR + 1))
        else
            cp "$f" "$body.tmp"
        fi
    else
        cp "$f" "$body.tmp"
    fi

    # Title-Case SUBSECTION 마커 치환 (판정: col-3 시작 + 소문자 1+ = Title-Case)
    awk -v hmap="$hmap" '
        function is_title_subsection(s) {
            return (s ~ /^   [A-Z][a-zA-Z -]*[a-z][a-zA-Z -]*$/ && length(s) < 60)
        }
        is_title_subsection($0) {
            idx++
            printf "[[[MANKO_HDR_%03d]]]\n", idx
            printf "%d\t%s\n", idx, $0 >> hmap
            next
        }
        { print }
    ' "$body.tmp" > "$body"
    rm -f "$body.tmp"

    printf "%s\t%d\n" "$bn" "$prefix_n" >> "$ANCHOR_MAP"
    nh=$(wc -l < "$hmap")
    TOTAL_HDR=$((TOTAL_HDR + nh))
done
echo "   -> $TOTAL_HDR headers stripped, $TOTAL_ANCHOR anchors injected across $N_CHUNKS chunks" >&2

# 4) 번역 (~/.zshrc manko() 베이스 + TODO.md 번역 금지 규칙 통합)
echo "[4/5] Translating with $MODEL_KEY..." >&2
PROMPT='당신은 man page 번역 전문가입니다. 아래 텍스트를 한국어로 번역하세요. 짧은 텍스트라도 그대로 번역하고, 다른 응답(요청·확인·설명) 절대 금지.

핵심 규칙 (가장 중요):
- 모든 영문 문장·설명문을 한국어 문장으로 변환. 영문 원문을 그대로 복사·echo 하지 말 것.
- 설명문이 이미 명확해 보여도, 옵션 정의/구성도 본문/주석이든 모두 한국어로 변환.
- 번역 대상이 짧거나 기술 용어가 많아도 반드시 한국어로 출력.

형식 규칙:
- 마크다운 문법 사용 금지(bold/italic/list 마커 등)
- 각 줄의 시작 공백(들여쓰기)과 개행 위치를 원문 그대로 유지
- [[[MANKO_HDR_NNN]]] 형태의 표식은 번역하지 말고 그대로 출력 (독립된 한 줄)
- 다음은 원문 그대로 유지(번역 금지): 전부 대문자인 섹션 헤더(NAME, DESCRIPTION, GLOBAL OPTIONS 등), 옵션명(-a, --all), 대문자 식별자(FILE, GNU, NO WARRANTY, POSIXLY_CORRECT 등), 명령어/함수명(cat, tac(1)), URL/이메일/경로, 괄호와 특수기호([ ] { } < > | & *)

예시:
  원문: "     -d     A synonym for -depth, for compatibility with FreeBSD."
  번역: "     -d     FreeBSD 호환성을 위한 -depth의 동의어."

  원문: "            0      Equivalent to optimisation level 1."
  번역: "            0      최적화 레벨 1과 동일합니다."

번역할 텍스트:'

# gemma-4-E4B 출력 파서 (조건별 마커 모두 처리):
#   - 답변 시작: 마지막 [End thinking] 또는 (truncated) 이후
#     · 짧은 프롬프트면 thinking 출력, 강한 프롬프트면 thinking 생략 → 둘 다 대응
#   - 답변 종료: 첫 [ Prompt: 또는 Exiting
#   - 단독 "> " 라인 스킵
parse_llama_output() {
    awk '
        { lines[NR] = $0 }
        /\(truncated\)/        { start = NR + 1 }
        /^\[End thinking\]/    { start = NR + 1 }
        /^\[ Prompt:/ && !end  { end = NR - 1 }
        /^Exiting/    && !end  { end = NR - 1 }
        END {
            if (!start) start = 1
            if (!end)   end   = NR
            for (i = start; i <= end; i++) {
                if (lines[i] ~ /^> *$/) continue
                print lines[i]
            }
        }
    '
}

# src/trans 일치율 측정 — trans 의 non-empty 줄 중 몇 %가 src 에도 그대로 있는가.
# 높을수록 모델이 번역 대신 원문을 echo 한 실패 모드 (find_003 의 GLOBAL OPTIONS 케이스).
chunk_echo_ratio() {
    awk '
        NR==FNR { src[$0] = 1; next }
        NF > 0  { total++; if ($0 in src) same++ }
        END     { if (total == 0) print 0; else printf "%d", same * 100 / total }
    ' "$1" "$2"
}

# 단일 청크 번역. retry=0 은 결정론(temp 0), retry>=1 은 temp 0.3 + 프롬프트 보강
# (사고 과정 생략 지시) 으로 다른 궤적 생성 유도.
translate_chunk() {
    local f="$1" out="$2" retry="${3:-0}"
    local temp="0.0" extra=""
    if [ "$retry" -gt 0 ]; then
        temp="0.3"
        extra=$'\n중요 (이전 시도가 영문 echo 실패): 사고 과정 출력 금지. 입력의 모든 줄을 반드시 한국어로 변환하여 첫 줄부터 출력. 영문 문장을 그대로 반복하지 말 것. 옵션 정의("-d A synonym...")도 반드시 번역("-d ... 의 동의어").'
    fi
    echo "/exit" | llama-cli \
        -m "$MODEL" \
        -ngl 99 -c 12288 -t 8 \
        --temp "$temp" --top-p 1.0 --top-k 0 --repeat-penalty 1.0 \
        -ctk q8_0 -ctv q8_0 \
        "${LLAMA_EXTRA_ARGS[@]}" \
        --log-disable --no-display-prompt --offline --simple-io \
        -p "$(printf '%s%s\n\n' "$PROMPT" "$extra"; cat "$f")" \
        2>/dev/null | parse_llama_output > "$out" || true
}

ECHO_THRESHOLD=50   # trans 의 이 %만큼 src 와 일치하면 echo 실패로 간주
MAX_RETRY=1

# 마커 → 원본 헤더 복원 + synthetic anchor prefix strip.
# 모델이 [[[MANKO_HDR_NNN]]] 를 어떤 줄에 출력했든 그 자리에 headers_dir/$bn.txt 에서
# 가져온 원본 헤더 라인을 삽입. 모델이 마커를 분실했거나 번역해 버리면 복원되지 않으므로
# 단계 5 의 force-restore 가 2중 안전망.
# prefix_n 줄은 synthetic anchor 이므로 leading blank skip 후 앞에서부터 strip.
restore_headers() {
    local raw="$1" hmap="$2" out="$3" prefix_n="${4:-0}"
    awk -v hmap="$hmap" -v prefix_n="$prefix_n" '
        BEGIN {
            while ((getline line < hmap) > 0) {
                split(line, a, "\t")
                hdr[a[1]] = a[2]
            }
            close(hmap)
            stripped = 0
        }
        # leading blank lines: 유지 (step 5 가 skip 함)
        !started && /^[[:space:]]*$/ { print; next }
        { started = 1 }
        # prefix_n 줄 strip (synthetic anchor — 번역되었든 원문이든 버림)
        stripped < prefix_n { stripped++; next }
        {
            if (match($0, /\[\[\[MANKO_HDR_([0-9]+)\]\]\]/, m)) {
                idx = m[1] + 0
                if (idx in hdr) { print hdr[idx]; next }
            }
            print
        }
    ' "$raw" > "$out"
}

COUNT=0
for b in "$BODIES_DIR"/*.txt; do
    COUNT=$((COUNT + 1))
    bn=$(basename "$b" .txt)
    raw_out="$TRANS_DIR/$bn.raw.txt"
    trans_out="$TRANS_DIR/$bn.txt"
    hmap="$HEADERS_DIR/$bn.txt"
    printf "  [%d/%d] %s ...\n" "$COUNT" "$N_CHUNKS" "$bn" >&2

    translate_chunk "$b" "$raw_out" 0
    attempt=0
    while [ "$attempt" -lt "$MAX_RETRY" ]; do
        ratio=$(chunk_echo_ratio "$b" "$raw_out")
        [ "$ratio" -lt "$ECHO_THRESHOLD" ] && break
        attempt=$((attempt + 1))
        printf "    ⚠ 원문 일치율 %s%% (≥%s%%) — 재시도 %d/%d\n" \
            "$ratio" "$ECHO_THRESHOLD" "$attempt" "$MAX_RETRY" >&2
        translate_chunk "$b" "$raw_out" "$attempt"
    done
    final_ratio=$(chunk_echo_ratio "$b" "$raw_out")
    if [ "$final_ratio" -ge "$ECHO_THRESHOLD" ]; then
        printf "    ✗ 재시도 후에도 일치율 %s%% — 번역 실패 상태로 출력\n" "$final_ratio" >&2
    fi

    prefix_n=$(awk -v bn="$bn" -F'\t' '$1 == bn { print $2; exit }' "$ANCHOR_MAP")
    [ -z "$prefix_n" ] && prefix_n=0
    restore_headers "$raw_out" "$hmap" "$trans_out" "$prefix_n"
done

# 5) 후처리: 섹션 헤더 앵커 정렬 + 들여쓰기 복원 + 청크 이음새 정리
#
# 알고리즘:
#  (a) 앵커 정렬 — src 의 col-0 ALL-CAPS 섹션 헤더와 trans 의 col-0 "헤더 후보" (refined filter)
#      를 순서대로 매칭. 개수 일치 시 trans 쪽 자리를 src 영문으로 치환 (COMMENTS↔주석 같은
#      번역 누출 교정). 동시에 이 위치들을 "앵커"로 기록.
#  (b) 인덱스 매칭 — leading 빈 줄 skip 후 j++ 로 src FNR 매칭. 앵커 위치가 정렬됨을 알기에
#      기존 force-restore(잘못된 offset 덮어쓰기) 로직 불필요 — 앵커 자리는 이미 영문.
#  (c) indent 복원 — 줄 수 차이가 임계 이내면 src 들여쓰기 덮어쓰기, 초과 시 skip.
echo "[5/5] Post-processing..." >&2
: > "$RESULT"
MISMATCH_THRESHOLD_PCT=20
for src in "$CHUNKS_DIR"/*.txt; do
    bn=$(basename "$src" .txt)
    trans="$TRANS_DIR/$bn.txt"
    post="$POST_DIR/$bn.txt"
    [ -f "$trans" ] || continue

    src_n=$(wc -l < "$src")

    awk -v bn="$bn" '
        function abs(x) { return x < 0 ? -x : x }
        function hdr_candidate(s) {
            if (s !~ /^[A-Z가-힣]/) return 0
            if (s ~ /\t/) return 0
            if (s ~ /  /) return 0
            if (s ~ /[.,:;]/) return 0
            if (length(s) >= 30) return 0
            if (length(s) <= 1) return 0
            return 1
        }
        NR==FNR {
            match($0, /^[ \t]*/)
            ind[FNR] = substr($0, 1, RLENGTH)
            src_line[FNR] = $0
            if ($0 ~ /^[A-Z][A-Z0-9 ()-]+$/ && length($0) >= 2 && length($0) < 50) {
                src_hdr_pos[++n_src_h] = FNR
                src_hdr_text[n_src_h] = $0
            }
            n_src = FNR
            next
        }
        { tl[++n_trans] = $0 }
        END {
            # trans 헤더 후보 수집
            for (t = 1; t <= n_trans; t++) {
                if (hdr_candidate(tl[t])) trans_hdr_pos[++n_trans_h] = t
            }

            # 앵커 정렬 (Level 1: 섹션 헤더) — 개수 일치 시 src 영문으로 치환
            aligned = (n_src_h > 0 && n_trans_h == n_src_h)
            if (aligned) {
                for (k = 1; k <= n_src_h; k++) {
                    pos = trans_hdr_pos[k]
                    tl[pos] = src_hdr_text[k]
                }
            }

            t_start = 1
            while (t_start <= n_trans && tl[t_start] ~ /^[[:space:]]*$/) t_start++

            # 최상위 세그먼트 (섹션 헤더 사이)
            if (aligned) {
                n_seg = n_src_h + 1
                src_seg_lo[0] = 1; src_seg_hi[0] = src_hdr_pos[1] - 1
                trans_seg_lo[0] = t_start; trans_seg_hi[0] = trans_hdr_pos[1] - 1
                for (k = 1; k < n_src_h; k++) {
                    src_seg_lo[k] = src_hdr_pos[k] + 1
                    src_seg_hi[k] = src_hdr_pos[k+1] - 1
                    trans_seg_lo[k] = trans_hdr_pos[k] + 1
                    trans_seg_hi[k] = trans_hdr_pos[k+1] - 1
                }
                src_seg_lo[n_src_h] = src_hdr_pos[n_src_h] + 1; src_seg_hi[n_src_h] = n_src
                trans_seg_lo[n_src_h] = trans_hdr_pos[n_src_h] + 1; trans_seg_hi[n_src_h] = n_trans
            } else {
                n_seg = 1
                src_seg_lo[0] = 1; src_seg_hi[0] = n_src
                trans_seg_lo[0] = t_start; trans_seg_hi[0] = n_trans
            }

            # trans[t] → src[map[t]] 매핑 구축
            # 세그먼트별로:
            #   - 세그먼트 내 빈 줄(blank) 개수가 src/trans 동일 → blank 을 sub-anchor 로 1:1 페어링,
            #     sub-interval 안에서 길이 일치 시 1:1 매핑 (길이 불일치면 매핑 없음)
            #   - blank 개수 불일치 → 매핑 없음 (해당 세그먼트 전체 indent 복원 skip)
            skipped_subs = 0
            total_subs = 0
            for (k = 0; k < n_seg; k++) {
                src_lo = src_seg_lo[k]; src_hi = src_seg_hi[k]
                trans_lo = trans_seg_lo[k]; trans_hi = trans_seg_hi[k]
                if (src_lo > src_hi || trans_lo > trans_hi) continue

                # blank 위치 수집
                n_sb = 0; n_tb = 0
                delete sb; delete tb
                for (i = src_lo; i <= src_hi; i++) {
                    if (src_line[i] ~ /^[[:space:]]*$/) sb[++n_sb] = i
                }
                for (i = trans_lo; i <= trans_hi; i++) {
                    if (tl[i] ~ /^[[:space:]]*$/) tb[++n_tb] = i
                }

                if (n_sb != n_tb) {
                    total_subs++; skipped_subs++
                    continue   # 매핑 없음
                }

                # sub-intervals: (boundaries) [src_lo, sb[1]-1], [sb[1]+1, sb[2]-1], ..., [sb[N]+1, src_hi]
                # blank 자체는 tb[k] ↔ sb[k] 로 페어링 (길이 0 sub-interval)
                sb[0] = src_lo - 1; sb[n_sb + 1] = src_hi + 1
                tb[0] = trans_lo - 1; tb[n_tb + 1] = trans_hi + 1
                for (k2 = 0; k2 <= n_sb; k2++) {
                    s_from = sb[k2] + 1; s_to = sb[k2+1] - 1
                    t_from = tb[k2] + 1; t_to = tb[k2+1] - 1
                    s_len = s_to - s_from + 1
                    t_len = t_to - t_from + 1
                    total_subs++
                    if (s_len == t_len && s_len >= 0) {
                        for (off = 0; off < t_len; off++) {
                            map[t_from + off] = s_from + off
                        }
                    } else {
                        skipped_subs++
                    }
                }
                # blank ↔ blank 페어링
                for (k2 = 1; k2 <= n_sb; k2++) {
                    map[tb[k2]] = sb[k2]
                }
            }

            if (skipped_subs > 0) {
                printf("  ⚠ %s sub-interval %d/%d indent skip\n",
                       bn, skipped_subs, total_subs) > "/dev/stderr"
            }

            # 출력
            for (k = 0; k < n_seg; k++) {
                for (t = trans_seg_lo[k]; t <= trans_seg_hi[k]; t++) {
                    s = tl[t]
                    if ((t in map) && length(s) > 0) {
                        src_idx = map[t]
                        sub(/^[ \t]*/, "", s)
                        print ind[src_idx] s
                    } else {
                        print s
                    }
                }
                if (k < n_seg - 1 && aligned) {
                    print src_hdr_text[k + 1]   # col-0 영문 헤더
                }
            }
        }
    ' "$src" "$trans" > "$post"

    # 이음새 정리: 청크 시작/끝의 빈 줄을 1개로 압축
    awk '
        BEGIN { blank=0 }
        /^[[:space:]]*$/ { blank++; next }
        { if (blank > 0 && NR > 1) print ""; blank = 0; print }
        END { if (blank > 0) print "" }
    ' "$post" >> "$RESULT"
done

# OUT_FILE 이 지정되면 복사 (manko() 캐시 경로)
if [ -n "$OUT_FILE" ]; then
    mkdir -p "$(dirname "$OUT_FILE")"
    cp "$RESULT" "$OUT_FILE"
    echo "[out] $OUT_FILE" >&2
fi

echo "" >&2
echo "Result: $RESULT" >&2
echo "====================" >&2
cat "$RESULT"

#!/bin/bash
# 계층적 재귀 분할 + 탐욕 병합 청킹
# CLAUDE.md "청킹 전략" 의사코드 구현 (LangChain RecursiveCharacterTextSplitter 패턴).
#
# 5단계 separator: SECTION → SUBSECTION → ITEM(동적 indent) → PARAGRAPH → LINE.
# 초과(estimate > max_tok)인 청크만 다음 단계로 더 잘게 쪼갠다.
# 모든 단계 종료 후 탐욕 병합으로 작은 leaf 들을 한도 안에서 합쳐 청크 수를 최소화.
#
# 기존 `backup/chucking.sh` (SECTION 단독, 상위호환됨) 를 대체한다.
#
# 사용:
#   chunk_text <input_file> <output_dir> <prefix> <max_tokens>
#   결과: <output_dir>/<prefix>_001.txt, <prefix>_002.txt, ...

# ---- 토큰 추정 (CLAUDE.md 캐스케이드 2단계: lines×21, 무료) ----
_estimate_tokens_file() {
    local lines
    lines=$(wc -l < "$1")
    echo $((lines * 21))
}

# ---- ITEM 동적 indent 감지 ----
# 4..20 범위에서 >=3회 등장하는 가장 작은 indent 를 ITEM 헤더로 간주.
# 일반 man=7/14/21 → 7 선택. bash=5/12/19 → 5 선택.
# 0(SECTION) / 3(SUBSECTION) 은 별도 단계에서 처리하므로 자동 제외됨 (범위 밖).
_detect_item_indent() {
    awk '
        /^[ \t]*$/ { next }
        {
            match($0, /^ */)
            ind = RLENGTH
            if (ind >= 4 && ind <= 20) cnt[ind]++
        }
        END {
            for (i = 4; i <= 20; i++) {
                if (cnt[i] >= 3) { print i; exit }
            }
            print 0
        }
    ' "$1"
}

# ---- 단일 패스: in_dir 의 모든 청크를 walk, 초과인 것만 sep 로 분할 ----
# 입력 파일 순서를 유지하면서 out_dir 에 재시퀀스된 4-digit 파일로 기록.
_split_pass() {
    local in_dir="$1" out_dir="$2" sep="$3" max_tok="$4"
    local idx=0 f tmp est n_parts part out item_indent

    for f in "$in_dir"/*.txt; do
        [ -f "$f" ] || continue
        est=$(_estimate_tokens_file "$f")

        if [ "$est" -le "$max_tok" ]; then
            # 한도 내 → 그대로 유지 (다음 패스에도 건드리지 않음)
            idx=$((idx + 1))
            printf -v out "%s/%04d.txt" "$out_dir" "$idx"
            cp "$f" "$out"
            continue
        fi

        tmp=$(mktemp -d)
        case "$sep" in
            section)
                awk -v outdir="$tmp" '
                    function flush() {
                        if (n > 0) {
                            sub_idx++
                            f = sprintf("%s/%04d.txt", outdir, sub_idx)
                            for (i = 0; i < n; i++) print buf[i] > f
                            close(f); n = 0
                        }
                    }
                    /^[A-Z][A-Z0-9 ()-]*$/ && length($0) < 50 { flush() }
                    { buf[n++] = $0 }
                    END { flush() }
                ' "$f"
                ;;
            subsection)
                awk -v outdir="$tmp" '
                    function flush() {
                        if (n > 0) {
                            sub_idx++
                            f = sprintf("%s/%04d.txt", outdir, sub_idx)
                            for (i = 0; i < n; i++) print buf[i] > f
                            close(f); n = 0
                        }
                    }
                    /^   [A-Z][a-zA-Z][a-zA-Z -]*$/ { flush() }
                    { buf[n++] = $0 }
                    END { flush() }
                ' "$f"
                ;;
            item)
                item_indent=$(_detect_item_indent "$f")
                if [ "$item_indent" -gt 0 ]; then
                    awk -v outdir="$tmp" -v ind="$item_indent" '
                        function flush() {
                            if (n > 0) {
                                sub_idx++
                                f = sprintf("%s/%04d.txt", outdir, sub_idx)
                                for (i = 0; i < n; i++) print buf[i] > f
                                close(f); n = 0
                            }
                        }
                        BEGIN {
                            pat = "^"
                            for (k = 0; k < ind; k++) pat = pat " "
                            pat = pat "[^ ]"
                        }
                        $0 ~ pat { flush() }
                        { buf[n++] = $0 }
                        END { flush() }
                    ' "$f"
                fi
                ;;
            paragraph)
                # 빈 줄을 소거하지 않고 새 청크의 첫 줄로 남겨둬서 줄 수 보존.
                # section/subsection/item 도 동일 방식(경계 라인을 다음 청크의 첫 줄로).
                awk -v outdir="$tmp" '
                    function flush() {
                        if (n > 0) {
                            sub_idx++
                            f = sprintf("%s/%04d.txt", outdir, sub_idx)
                            for (i = 0; i < n; i++) print buf[i] > f
                            close(f); n = 0
                        }
                    }
                    /^[[:space:]]*$/ { flush() }
                    { buf[n++] = $0 }
                    END { flush() }
                ' "$f"
                ;;
            line)
                echo "WARN: line-level fallback for $(basename "$f") (est=$est tok)" >&2
                awk -v outdir="$tmp" '
                    {
                        f = sprintf("%s/%04d.txt", outdir, NR)
                        print > f
                        close(f)
                    }
                ' "$f"
                ;;
        esac

        n_parts=$(find "$tmp" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l)
        if [ "$n_parts" -le 1 ]; then
            # 분할 실패 (separator 미존재) → 원본 유지, 다음 패스에 위임
            idx=$((idx + 1))
            printf -v out "%s/%04d.txt" "$out_dir" "$idx"
            cp "$f" "$out"
        else
            for part in "$tmp"/*.txt; do
                idx=$((idx + 1))
                printf -v out "%s/%04d.txt" "$out_dir" "$idx"
                cp "$part" "$out"
            done
        fi
        rm -rf "$tmp"
    done
}

# ---- 탐욕 병합: 정렬된 leaf 들을 walk 하면서 한도 안에서 누적 ----
# 추정치(lines×21) 기반. 최종 정확 검증은 호출 측에서 llama-tokenize 로 수행.
_greedy_merge() {
    local in_dir="$1" out_dir="$2" prefix="$3" max_tok="$4"
    local buf="$in_dir/.greedy_buf"
    local idx=0 f f_lines combined est buf_lines=0 out

    : > "$buf"
    for f in "$in_dir"/*.txt; do
        [ -f "$f" ] || continue
        f_lines=$(wc -l < "$f")
        combined=$((buf_lines + f_lines))
        est=$((combined * 21))

        if [ "$buf_lines" -eq 0 ] || [ "$est" -le "$max_tok" ]; then
            cat "$f" >> "$buf"
            buf_lines=$combined
        else
            idx=$((idx + 1))
            printf -v out "%s/%s_%03d.txt" "$out_dir" "$prefix" "$idx"
            mv "$buf" "$out"
            cat "$f" > "$buf"
            buf_lines=$f_lines
        fi
    done
    if [ -s "$buf" ]; then
        idx=$((idx + 1))
        printf -v out "%s/%s_%03d.txt" "$out_dir" "$prefix" "$idx"
        mv "$buf" "$out"
    else
        rm -f "$buf"
    fi
}

# ---- 메인 ----
chunk_text() {
    local infile="$1" outdir="$2" prefix="$3" max_tok="$4"
    local workdir gen_a gen_b sep tmp current_in current_out

    workdir=$(mktemp -d)
    gen_a="$workdir/a"
    gen_b="$workdir/b"
    mkdir -p "$gen_a" "$gen_b" "$outdir"

    cp "$infile" "$gen_a/0001.txt"

    current_in="$gen_a"
    current_out="$gen_b"
    for sep in section subsection item paragraph line; do
        rm -f "$current_out"/*.txt
        _split_pass "$current_in" "$current_out" "$sep" "$max_tok"
        tmp="$current_in"; current_in="$current_out"; current_out="$tmp"
    done

    _greedy_merge "$current_in" "$outdir" "$prefix" "$max_tok"
    rm -rf "$workdir"
}

# CLI 단독 실행 지원
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    if [ $# -lt 4 ]; then
        echo "Usage: $0 <input_file> <output_dir> <prefix> <max_tokens>"
        exit 1
    fi
    chunk_text "$1" "$2" "$3" "$4"
fi

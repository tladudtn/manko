# manko

> man page → 한국어 번역기 (로컬 LLM)
> ./tmp/systemctl 에서 번역 결과를 볼 수 있습니다.

`man <command>` 출력을 llama.cpp + gemma-4-E4B 로 한국어 번역하는 셸 도구. [`man-pages-ko`](https://wariua.github.io/man-pages-ko/) 미지원 명령어 보완.

## Quick start

```bash
./run_translate.sh <command>
```

캐시 위치: `./tmp/<command>/<command>_ko.txt`

PoC 파이프라인 직접 실행:

```bash
./run_translate.sh systemctl    # 전체 파이프라인 stderr 로그
```

## 파이프라인

```
man 원문 → 계층적 재귀 청킹 → 토큰 검증(캐시) → 헤더 마커화 + 앵커 주입
         → gemma-4-E4B 청크별 번역 → 2단 앵커 후처리 → 병합 출력
```

청킹: 5단계 구분자 (`SECTION` → `SUBSECTION` → 동적 `ITEM` indent → `PARAGRAPH` → `LINE`) 재귀 분할 + 탐욕 병합. `MAX_INPUT_TOKENS=3500` 상한.

후처리: col-0 ALL-CAPS 헤더 + 세그먼트 내부 빈 줄을 2단 앵커로 정렬, src 들여쓰기 복원.

## 검증된 성능

| cmd | src 줄 | 청크 | 시간 | 섹션 헤더 보존 |
|-----|-------|------|------|--------------|
| cat | 74 | 1 | ~30s | n/a |
| ls | 243 | 2 | ~62s | ✓ |
| grep | 620 | 5 | ~4분 | ✓ |
| find | 1733 | 12 | ~9분 | 17/17 |
| systemctl | 2441 | 17 | ~13분 | 9/9 (+ 서브 7/7, 옵션 64/64) |
| bash | 7319 | 53 | ~30분 | 37/38 |

RTX 4070 Ti 12GB, gemma-4-E4B Q8_0 기준. 청크당 ~45s (cold load 병목).

## 디렉토리 구조

```
run_translate.sh            # 전체 파이프라인 PoC
recursive_chunk.sh          # 5단계 재귀 분할 + 탐욕 병합 청킹
token_utils.sh              # 3단 캐스케이드 토큰 측정 + content_hash 캐시
models/                     # GGUF 모델 파일 (내용 gitignored)
tmp/<command>/              # 명령어별 번역 산출물 (내용 gitignored)
  source.txt                #   man 원문
  chunks/                   #   청킹 결과
  bodies/ headers/          #   헤더 마커화 후 본문/헤더 맵
  trans/                    #   청크별 번역 원본
  post/                     #   후처리(앵커 정렬 + 들여쓰기 복원) 결과
  <command>_ko.txt          #   최종 병합 번역본
```

## 지원 모델

| MODEL_KEY | 파일 | VRAM | 비고 |
|-----------|------|------|------|
| `e4b` (기본) | gemma-4-E4B Q8_0 | ~5GB | 4B, 빠름, 현재 주력 |
| `26b` | gemma-4-26B-A4B Q4_K_M | 8-10GB + RAM | MoE, `--n-cpu-moe 99` 오프로드 |

## 테스트 환경

| 항목 | 사양 |
|------|------|
| CPU | Ryzen 7 7800X3D |
| GPU | RTX 4070 Ti (12GB) |
| MEM | DDR5 32GB |
| OS | Arch Linux |
| LLM | [llama.cpp-cuda-git](https://aur.archlinux.org/packages/llama.cpp-cuda) |

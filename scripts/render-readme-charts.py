# Writes the README evidence charts as SVG. Values come from docs/research/apple-speech-selection.ko.md.
from pathlib import Path
from html import escape

out = Path(__file__).resolve().parents[1] / "assets/readme/charts"
INK, SOFT, MUTED, GRID, SURFACE = "#22221f", "#5f5d56", "#8a887f", "#e6e4dc", "#fbfaf6"
HIGHLIGHT, CONTEXT = "#c4553f", "#b4b2a8"
FONT = "-apple-system, BlinkMacSystemFont, 'Apple SD Gothic Neo', 'Noto Sans KR', sans-serif"
W, LEFT, RIGHT = 880, 244, 112

def bar(x, y, w, h, color):
    # Square at the baseline, 4px rounded data end.
    r = min(4, w / 2)
    return (f'<path d="M{x},{y} H{x + w - r} Q{x + w},{y} {x + w},{y + r} V{y + h - r} '
            f'Q{x + w},{y + h} {x + w - r},{y + h} H{x} Z" fill="{color}"/>')

def chart(name, title, subtitle, rows, maximum, ticks, unit, note, bar_h=22, gap=22):
    top = 118
    height = top + len(rows) * (bar_h + gap) + 78
    plot = W - LEFT - RIGHT
    scale = lambda v: plot * v / maximum
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" viewBox="0 0 {W} {height}" font-family="{FONT}">',
             f'<title>{escape(title)}</title>',
             f'<rect width="{W}" height="{height}" rx="16" fill="{SURFACE}"/>',
             f'<text x="40" y="54" font-size="21" font-weight="700" fill="{INK}">{escape(title)}</text>',
             f'<text x="40" y="82" font-size="14" fill="{SOFT}">{escape(subtitle)}</text>']
    axis_y = top + len(rows) * (bar_h + gap) - gap / 2
    for t in ticks:
        x = LEFT + scale(t)
        parts.append(f'<line x1="{x}" y1="{top - 10}" x2="{x}" y2="{axis_y}" stroke="{GRID}" stroke-width="1"/>')
        parts.append(f'<text x="{x}" y="{axis_y + 20}" font-size="12" fill="{MUTED}" text-anchor="middle">{t:g}{unit}</text>')
    for i, (label, value, text, strong) in enumerate(rows):
        y = top + i * (bar_h + gap)
        weight = 700 if strong else 400
        parts.append(f'<text x="{LEFT - 16}" y="{y + bar_h / 2 + 5}" font-size="15" font-weight="{weight}" fill="{INK if strong else SOFT}" text-anchor="end">{escape(label)}</text>')
        parts.append(bar(LEFT, y, max(scale(value), 2), bar_h, HIGHLIGHT if strong else CONTEXT))
        parts.append(f'<text x="{LEFT + scale(value) + 10}" y="{y + bar_h / 2 + 5}" font-size="15" font-weight="{weight}" fill="{INK if strong else SOFT}">{escape(text)}</text>')
    parts.append(f'<text x="40" y="{height - 26}" font-size="12" fill="{MUTED}">{escape(note)}</text>')
    parts.append('</svg>')
    (out / f"{name}.svg").write_text("\n".join(parts))

chart("transcription-speed",
      "같은 15분 강의를 전사하는 데 걸린 시간",
      "금융 강의 15분 · 같은 18개 구간 · 교정·요약 제외 · 짧을수록 빠름",
      [("Apple Speech", 9.37, "9.37초 · 약 12.3배 빠름", True), ("기존 Whisper 구현", 115.64, "115.64초", False)],
      120, [0, 30, 60, 90, 120], "초",
      "둥둥이 자체 측정 · MacBook Air M1 8GB · macOS 26.3 · whisper.cpp large-v3-turbo + Silero VAD · 조건별 1회", bar_h=24, gap=26)

chart("korean-cer",
      "한국어 문자 오류율(CER)",
      "FLEURS 한국어 약 150문장 · 낮을수록 정확",
      [("Qwen3-ASR 1.7B", 3.54, "3.54%", False), ("Whisper Large V3 Turbo", 4.25, "4.25%", False),
       ("Apple SpeechTranscriber", 4.31, "4.31%", True), ("Apple Dictation", 7.11, "7.11%", False),
       ("Whisper Small", 7.30, "7.30%", False), ("SenseVoice Small", 7.85, "7.85%", False)],
      8, [0, 2, 4, 6, 8], "%",
      "출처: Whisper Notes Team, 2026-09-01 · M5 MacBook Air · 외부 측정이며 둥둥이가 재실행하지 않음")
print("charts written to", out)

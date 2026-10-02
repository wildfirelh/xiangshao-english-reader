"""Extract the cover's English subject mark without changing its proportions."""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'tools/icon_sources'


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with Image.open(ROOT / 'assets/textbooks/xiangshao_3_1/images/cover.webp') as cover:
        width, height = cover.size
        # The large subject title in the teal panel (not the certification seal).
        mark = cover.crop((round(width * .35), round(height * .202),
                           round(width * .635), round(height * .304))).convert('RGBA')
    mark = mark.resize((600, round(600 * mark.height / mark.width)), Image.Resampling.LANCZOS)
    background = Image.new('RGBA', (1024, 1024), (88, 170, 172, 255))
    # Keep the title inside the adaptive icon's central safe area.
    foreground = Image.new('RGBA', (1024, 1024))
    foreground.alpha_composite(mark, ((1024 - mark.width) // 2, (1024 - mark.height) // 2))
    foreground.save(OUTPUT / 'foreground.png')
    background.alpha_composite(foreground)
    background.convert('RGB').save(OUTPUT / 'launcher.png')
    print(f'Icon sources: {OUTPUT}')


if __name__ == '__main__':
    main()

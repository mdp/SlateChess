# Unique E-Reader Screen Resolutions (Kindle & Kobo)

Derived from the pasted comparison data. Resolutions are listed as pixels W×H (portrait orientation). Shared resolutions are noted so layout testing can group devices.

## Unique resolutions (combined Kindle + Kobo)

| # | Resolution (W×H) | Pixels | Pixel density | Aspect (W:H) | Used by |
|---|------------------|--------|---------------|--------------|---------|
| 1 | 600 × 800 | 0.48 MP | 167 PPI | 3:4 | Kindle 8, Kindle 10, Kobo Touch |
| 2 | 758 × 1024 | 0.78 MP | 212 PPI | 3:4 (approx.) | Kobo Nia |
| 3 | 1072 × 1448 | 1.55 MP | 300 PPI | 3:4 (approx.) | Kindle 11, Kindle 2024, Kindle Paperwhite 4, Kindle Voyage, Kindle Oasis (1st gen), Kobo Clara HD / Clara 2E / Clara BW / Clara Colour, Kobo Glo HD |
| 4 | 1236 × 1648 | 2.04 MP | 300 PPI | 3:4 (approx.) | Kindle Paperwhite 5 (incl. Signature Edition) |
| 5 | 1264 × 1680 | 2.12 MP | 300 PPI (150 PPI on color panels) | 3:4 (approx.) | Kindle Paperwhite 6 (incl. Signature), Kindle Colorsoft (incl. Signature Edition), Kindle Oasis 2, Kindle Oasis 3, Kobo Libra 2 / Libra Colour / Libra H2O / Forma |
| 6 | 1404 × 1872 | 2.63 MP | 227 PPI | 4:3 rotated (approx. 3:4) | Kobo Elipsa, Kobo Elipsa 2E |
| 7 | 1440 × 1920 | 2.76 MP | 300 PPI | 3:4 | Kobo Sage |
| 8 | 1860 × 2480 | 4.61 MP | 300 PPI | 3:4 | Kindle Scribe (2022), Kindle Scribe (2024) |
| 9 | 1980 × 2640 | 5.23 MP | 300 PPI | 3:4 | Kindle Scribe 3, Kindle Scribe 3 without Front Light, Kindle Scribe Colorsoft |

## Kindle-only list

| Resolution | Devices |
|------------|---------|
| 600 × 800 | Kindle 8 (2016), Kindle 10 (2019) |
| 1072 × 1448 | Kindle 11, Kindle 2024, Paperwhite 4, Voyage, Oasis (1st gen) |
| 1236 × 1648 | Paperwhite 5, Paperwhite 5 Signature Edition |
| 1264 × 1680 | Paperwhite 6 (incl. Signature), Colorsoft (incl. Signature Edition), Oasis 2, Oasis 3 |
| 1860 × 2480 | Scribe (2022), Scribe (2024) |
| 1980 × 2640 | Scribe 3, Scribe 3 without Front Light, Scribe Colorsoft |

## Kobo-only list

| Resolution | Devices |
|------------|---------|
| 600 × 800 | Kobo Touch (Original) |
| 758 × 1024 | Kobo Nia |
| 1072 × 1448 | Clara HD, Clara 2E, Clara BW, Clara Colour, Glo HD |
| 1264 × 1680 | Libra 2, Libra Colour, Libra H2O, Forma |
| 1404 × 1872 | Elipsa, Elipsa 2E |
| 1440 × 1920 | Sage |

## Notes for layout testing

- **Total unique resolutions: 9** (6 Kindle, 6 Kobo, with 3 shared: 600×800, 1072×1448, 1264×1680).
- All resolutions are either ~3:4 portrait (or 4:3 landscape); the Elipsa/Elipsa 2E and Nia ratios are approximate.
- Color E Ink panels (Kaleido 3: Colorsoft models, Kobo Libra Colour, Clara Colour) render color at half the stated pixel density (e.g. 150 PPI vs 300 PPI).
- The 1980×2640 figure for the Scribe 3 generation is marked "TBC" in the source data.
- Smallest viewport for testing: 600×800; largest: 1980×2640.

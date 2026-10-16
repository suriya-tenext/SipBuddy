# Tools

Run from `windows/`:

- `npx electron tools/contact.js out.png [ids] [cellPx]`: contact sheet of every hero in every pose, for comparing against the Swift renderer.
- `npx electron tools/demo.js <outDir> [frames|stills|all]`: renders the README media. `stills` writes `banner.png` and `heroes.png`; `frames` writes the 24-second demo as 30 fps PNGs. Encode them with ffmpeg:

  ```sh
  ffmpeg -framerate 30 -i frames/f%04d.png -c:v libx264 -pix_fmt yuv420p -crf 20 demo.mp4
  ffmpeg -framerate 30 -i frames/f%04d.png -vf "fps=15,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse" demo.gif
  ```

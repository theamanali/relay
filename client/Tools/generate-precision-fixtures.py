#!/usr/bin/env python3
"""Local decoder fixtures, not PC desktop-capture proof. Requires ffmpeg/libx265/libx264.
YUV limited-range SDR: 64 consecutive 10-bit luma codes at x=32...95,
y=32...95; neutral chroma. 8-bit controls quantize the same ramp to 17 codes.
Top patches check black, white, red, green, blue (BT.601 matrix as host VUI).
Lossless coding isolates hardware decode/rendering from encoder quantization.
"""
import array
from pathlib import Path
import subprocess
import tempfile

out = Path(__file__).resolve().parents[1] / 'Tests/RelayTests/Fixtures'
out.mkdir(parents=True, exist_ok=True)
w, h = 256, 128
for depth, chroma, codec in [(8, 420, 'hevc'), (8, 444, 'hevc'),
                              (10, 420, 'hevc'), (10, 444, 'hevc'), (8, 420, 'h264')]:
    def code(x, y):
        if y < 16:
            return [(64,512,512),(940,512,512),(324,360,960),
                    (580,216,136),(164,960,440)][min(x//48,4)]
        return (400 + min(max(x-32,0),63), 512, 512)
    def pack(vals):
        return array.array('H', vals).tobytes() if depth == 10 else bytes((v+2)//4 for v in vals)
    raw = pack([code(x,y)[0] for y in range(h) for x in range(w)])
    step = 2 if chroma == 420 else 1
    for channel in [1,2]:
        raw += pack([code(x,y)[channel] for y in range(0,h,step) for x in range(0,w,step)])
    fmt = f'yuv{chroma}p' + ('10le' if depth == 10 else '')
    with tempfile.NamedTemporaryFile() as f:
        f.write(raw); f.flush()
        cmd = ['ffmpeg','-v','error','-y','-f','rawvideo','-pixel_format',fmt,'-video_size',f'{w}x{h}',
               '-framerate','60','-i',f.name,'-frames:v','1','-c:v','libx265' if codec == 'hevc' else 'libx264']
        if codec == 'hevc':
            cmd += ['-x265-params','lossless=1:keyint=1:bframes=0:repeat-headers=1:aud=1:log-level=error:pools=1']
        else:
            cmd += ['-qp','0','-x264-params','keyint=1:bframes=0:repeat-headers=1:aud=1']
        cmd += ['-color_range','tv','-colorspace','smpte170m','-color_primaries','bt709','-color_trc','bt709',
                str(out/f'{chroma}-{depth}.{codec}')]
        subprocess.run(cmd,check=True)

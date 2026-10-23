from pathlib import Path
from PIL import Image, ImageDraw

# Small monochrome template icons; shape conveys state without relying on colour.
root=Path(__file__).resolve().parents[1]/'assets'/'tray'
root.mkdir(parents=True,exist_ok=True)
for state in ('idle','ready','pending','failed'):
 im=Image.new('RGBA',(72,72),(0,0,0,0));d=ImageDraw.Draw(im)
 d.rounded_rectangle((9,24,43,47),radius=11,outline='black',width=5)
 d.rounded_rectangle((29,24,63,47),radius=11,outline='black',width=5)
 if state=='ready':
  d.ellipse((41,42,70,71),fill='white'); d.line((46,56,53,63,65,48),fill='black',width=5)
 elif state=='failed':
  d.ellipse((41,42,70,71),fill='white');d.line((49,49,63,63),fill='black',width=5);d.line((63,49,49,63),fill='black',width=5)
 elif state=='pending':
  d.ellipse((41,42,70,71),fill='white');d.arc((46,47,66,67),25,315,fill='black',width=5)
 else:
  d.ellipse((41,42,70,71),fill='white');d.line((48,57,64,57),fill='black',width=5)
 # Use transparent black strokes for template badges, not opaque white backgrounds.
 px=im.load()
 for y in range(im.height):
  for x in range(im.width):
   if px[x,y][:3]==(255,255,255):px[x,y]=(0,0,0,0)
 im.resize((36,36),Image.Resampling.LANCZOS).save(root/(state+'.png'))
 # Windows uses coloured ICO artwork rather than black macOS template strokes.
 colours={'idle':(100,116,139),'ready':(22,163,110),'pending':(217,119,6),'failed':(220,60,65)}
 coloured=Image.new('RGBA',im.size,(*colours[state],0));coloured.putalpha(im.getchannel('A'))
 coloured.save(root/('windows_'+state+'.ico'),sizes=[(16,16),(24,24),(32,32),(48,48),(64,64)])
print('Generated four status-shape icons')

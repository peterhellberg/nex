// Minimal C cart built against vex.h.
#include "vex.h"

static int t;

VEX_EXPORT("boot") void boot(void) { title("nex - hello.c"); }

VEX_EXPORT("update") void update(void) {
  t++;
  cls(1);
  for (int i = 0; i < 16; i++)
    rect(8 + i * 19, 150, 17, 17, i);
  circ(160 + (t % 120) - 60, 90, 12, 10);
  text("HELLO FROM C", 8, 8, 12);
  if (btnp(VEX_Z))
    tone(VEX_TONE_SLIDE(440, 880),
         VEX_TONE_DURATION(0, 0, 10, 6),
         VEX_TONE_VOLUME(80, 0),
         VEX_TONE_FLAGS(0, VEX_TONE_MODE1, 0));
}
